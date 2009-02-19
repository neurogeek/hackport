module Merge where

import Control.Monad.Error
import Control.Exception
import Data.Char
import Data.Maybe
import Data.List
import Data.Version
import Distribution.Package
import Distribution.Compiler (CompilerId(..), CompilerFlavor(GHC))
import Distribution.PackageDescription ( PackageDescription(..), FlagName(..) )
import Distribution.PackageDescription.Configuration
         ( finalizePackageDescription )
-- import Distribution.PackageDescription.Parse ( showPackageDescription )
import Distribution.Simple.PackageIndex (PackageIndex)
import Distribution.Text (display)

import System.Directory ( getCurrentDirectory
                        , setCurrentDirectory
                        , createDirectoryIfMissing
                        )
import System.IO
import System.Cmd (system)
import System.FilePath ((</>), splitPath, joinPath, takeFileName)
import qualified Data.Map as Map

import qualified Cabal2Ebuild as E
-- import Cache
import Error as E
import Overlays

import qualified Distribution.Package as Cabal
import qualified Distribution.Version as Cabal

import Distribution.System (buildOS, buildArch)
import Distribution.Verbosity
import Distribution.Simple.Utils

import Network.URI
import Network.HTTP

import Cabal2Ebuild

import Distribution.Client.IndexUtils ( getAvailablePackages )
import qualified Distribution.Simple.PackageIndex as Index
import Distribution.Client.Types

import qualified Portage.PackageId as Portage
import qualified Portage.Version as Portage
import qualified Portage.Overlay as Overlay

import Cabal2Ebuild

-- This is just a hack to simplify version ranges.
-- Backported from Cabal HEAD to work with Cabal 1.6.
-- Replace this module once it's included in a cabal release.
import CabalDistributionVersion (simplifyVersionRange)

a <-> b = a ++ '-':b
a <.> b = a ++ '.':b

{-
Requested features:
  * Create an ebuild for the cabal package
      - Copy the old keywords and ~arch them
  * Download the tarball and digest
  * Add files to darcs?
  * Print diff with the next latest version?
-}

readPackageString :: [String]
                  -> Either HackPortError ( Maybe Portage.Category
                                          , Cabal.PackageName
                                          , Maybe Portage.Version
                                          )
readPackageString args = do
  packageString <-
    case args of
      [] -> Left (ArgumentError "Need an argument, [category/]package[-version]")
      [pkg] -> return pkg
      _ -> Left (ArgumentError ("Too many arguments: " ++ unwords args))
  case Portage.parseFriendlyPackage packageString of
    Just v@(_,_,Nothing) -> return v
    -- we only allow versions we can convert into cabal versions
    Just v@(_,_,Just (Portage.Version _ Nothing [] 0)) -> return v
    _ -> Left (ArgumentError ("Could not parse [category/]package[-version]: " ++ packageString))

-- | If a package already exist in the overlay, find which category it has.
-- If it does not exist, we default to \'dev-haskell\'.
resolveCategory :: Verbosity -> Overlay.Overlay -> Cabal.PackageName -> IO Portage.Category
resolveCategory verbosity overlay pn = do
  info verbosity "Searching for which category to use..."
  case resolveCategories overlay pn of
    [] -> do
      info verbosity "No previous version of this package, defaulting category to dev-haskell."
      return devhaskell
    [cat] -> do
      info verbosity $ "Exact match of already existing package, using category: "
                         ++ display cat
      return cat
    cats -> do
      warn verbosity $ "Multiple matches of categories: " ++ unwords (map display cats)
      if devhaskell `elem` cats
        then do notice verbosity "Defaulting to dev-haskell"
                return devhaskell
        else do warn verbosity "Multiple matches and no known default. Override by specifying "
                warn verbosity "package category like so  'hackport merge categoryname/package[-version]."
                throwEx (ArgumentError "Specify package category and try again.")
  where
  devhaskell = Portage.Category "dev-haskell"

resolveCategories :: Overlay.Overlay -> Cabal.PackageName -> [Portage.Category]
resolveCategories overlay pn =
  [ cat 
  | (Portage.PackageName cat pn') <- Map.keys om
  , pn == Portage.normalizeCabalPackageName pn'
  ]
  where
    om = Overlay.overlayMap overlay

-- | Given a list of available packages, and maybe a preferred version,
-- return the available package with that version. Latest version is chosen
-- if no preference.
resolveVersion :: [AvailablePackage] -> Maybe Cabal.Version -> Maybe AvailablePackage
resolveVersion avails Nothing = Just $ maximumBy (comparing packageInfoId) avails
resolveVersion avails (Just ver) = listToMaybe (filter match avails)
  where
    match avail = ver == pkgVersion (packageInfoId avail)

merge :: Verbosity -> Repo -> URI -> [String] -> IO ()
merge verbosity repo serverURI args = do
  (m_category, user_pName, m_version) <-
    case readPackageString args of
      Left err -> throwEx err
      Right (c,p,m_v) ->
        case m_v of
          Nothing -> return (c,p,Nothing)
          Just v -> case Portage.toCabalVersion v of
                      Nothing -> throwEx (ArgumentError "illegal version")
                      Just ver -> return (c,p,Just ver)

  debug verbosity $ "Category: " ++ show m_category
  debug verbosity $ "Package: " ++ show user_pName
  debug verbosity $ "Version: " ++ show m_version

  let (Cabal.PackageName user_pname_str) = user_pName

  overlayPath <- getOverlayPath verbosity
  overlay <- Overlay.loadLazy overlayPath
  index <- fmap packageIndex $ getAvailablePackages verbosity [ repo ]

  -- find all packages that maches the user specified package name
  availablePkgs <-
    case Index.searchByName index user_pname_str of
      Index.None -> throwEx (PackageNotFound user_pname_str)
      Index.Ambiguous pkgs -> throwEx (ArgumentError ("Ambiguous name: " ++ unwords (map show pkgs)))
      Index.Unambiguous pkg -> return pkg

  -- select a single package taking into account the user specified version
  selectedPkg <-
    case resolveVersion availablePkgs m_version of
      Nothing -> do
        putStrLn "No such version for that package, available versions:"
        forM_ availablePkgs $ \ avail ->
          putStrLn (display . packageInfoId $ avail)
        throwEx (ArgumentError "no such version for that package")
      Just avail -> return avail

  -- print some info
  info verbosity "Selecting package:"
  forM_ availablePkgs $ \ avail -> do
    let match_text | packageInfoId avail == packageInfoId selectedPkg = "* "
                   | otherwise = "- "
    info verbosity $ match_text ++ (display . packageInfoId $ avail)

  let cabal_pkgId = packageInfoId selectedPkg
      cabal_pkgName = packageName cabal_pkgId
      pkgVer = packageVersion cabal_pkgId
      norm_pkgId = Portage.normalizeCabalPackageId cabal_pkgId
      norm_pkgName = packageName norm_pkgId
  category <- resolveCategory verbosity overlay norm_pkgName

  let pkgGenericDesc = packageDescription selectedPkg
      Right (pkgDesc0, flags) =
        finalizePackageDescription
          [ -- XXX: common things we should enable/disable?
            -- (FlagName "small_base", True) -- try to use small base
          ]
          (Nothing :: Maybe (PackageIndex PackageIdentifier))
          buildOS buildArch
          (CompilerId GHC (Version [6,10,1] []))
          [] pkgGenericDesc
      pkgDesc = let deps = [ Dependency pn (simplifyVersionRange vr)
                           | Dependency pn vr <- buildDepends pkgDesc0
                           ]
                in pkgDesc0 { buildDepends = deps }
                    
  debug verbosity ("Selected flags: " ++ show flags)
  -- debug verbosity ("Finalized package:\n" ++ showPackageDescription pkgDesc)

               -- TODO: more fixes
  let ebuild = fixSrc serverURI (packageId pkgDesc) (E.cabal2ebuild pkgDesc)
      ebuildName = display category
                   </> display norm_pkgId

  mergeEbuild verbosity overlayPath (Portage.unCategory category) ebuild
  fetchAndDigest
    verbosity
    (overlayPath </> display category </> display norm_pkgName)
    (display cabal_pkgId <.> "tar.gz")
    (mkUri cabal_pkgId)

mkUri :: Cabal.PackageIdentifier -> URI
mkUri pid =
   -- example:
   -- http://hackage.haskell.org/packages/archive/Cabal/1.4.0.2/Cabal-1.4.0.2.tar.gz
   fromJust $ parseURI $
    "http://hackage.haskell.org/packages/archive/"
             </> name </> ver </> name <-> ver <.> "tar.gz"
  where
    ver = display (packageVersion pid)
    name = display (packageName pid)

fetchAndDigest :: Verbosity
               -> FilePath -- ^ directory of ebuild
               -> String -- ^ tarball name
               -> URI -- ^ tarball uri
               -> IO ()
fetchAndDigest verbosity ebuildDir tarballName tarballURI =
  withWorkingDirectory ebuildDir $ do
    notice verbosity $ "Fetching " ++ show tarballURI
    response <- simpleHTTP (Request tarballURI GET [] "")
    case response of
      Left err -> throwEx (E.DownloadFailed (show tarballURI) (show err))
      Right response -> do
        let tarDestination = "/usr/portage/distfiles" </> tarballName
        notice verbosity $ "Saving to " ++ tarDestination
        writeFile tarDestination (rspBody response)
        notice verbosity "Recalculating digests..."
        system "repoman manifest"
        return ()

withWorkingDirectory :: FilePath -> IO a -> IO a
withWorkingDirectory newDir action = do
  oldDir <- getCurrentDirectory
  bracket
    (setCurrentDirectory newDir)
    (\_ -> setCurrentDirectory oldDir)
    (\_ -> action)

mergeEbuild :: Verbosity -> FilePath -> String -> EBuild -> IO () 
mergeEbuild verbosity target category ebuild = do 
  let edir = target </> category </> name ebuild
      elocal = name ebuild ++"-"++ version ebuild <.> "ebuild"
      epath = edir </> elocal
  createDirectoryIfMissing True edir
  info verbosity $ "Writing " ++ elocal
  writeFile epath (showEBuild ebuild)

fixSrc :: URI -> PackageIdentifier -> EBuild -> EBuild
fixSrc serverURI p ebuild =
  ebuild {
    src_uri = show $ serverURI {
      uriPath =
        uriPath serverURI
          </> display (pkgName p) 
          </> display (pkgVersion p) 
          </> display (pkgName p) ++ "-" ++ display (pkgVersion p) 
          <.> "tar.gz"
      } 
    }
