{-# LANGUAGE GeneralizedNewtypeDeriving #-}

module HsDev.Symbols.Resolve (
	ResolveM(..), ResolvedTree, ResolvedModule(..), resolvedTopScope, ImportedDeclaration(..),
	resolve, resolveModule, exported, resolveImport,
	mergeImported
	) where

import Control.Applicative
import Control.Arrow
import Control.Monad.Reader
import Control.Monad.State
import Data.Foldable (Foldable)
import Data.Function (on)
import Data.List (sortBy, groupBy, find)
import Data.Map (Map)
import qualified Data.Map as M
import Data.Maybe (fromMaybe, maybeToList)
import Data.Ord (comparing)
import Data.String (fromString)
import Data.Text (Text)
import qualified Data.Text as T
import Data.Traversable (Traversable, traverse)
import System.FilePath

import HsDev.Database
import HsDev.Project
import HsDev.Symbols
import HsDev.Symbols.Util

-- | Resolve monad uses existing @Database@ and @ResolvedTree@ as state.
newtype ResolveM a = ResolveM { runResolveM :: ReaderT Database (State ResolvedTree) a }
	deriving (Functor, Applicative, Monad, MonadState ResolvedTree, MonadReader Database)

-- | Tree of resolved modules
type ResolvedTree = Map ModuleId ResolvedModule

-- | Module with declarations bringed to scope and with exported declarations
data ResolvedModule = ResolvedModule {
	resolvedModule :: Module,
	resolvedScope :: [ImportedDeclaration],
	resolvedExports :: [Declaration] }

-- | Get top-level scope
resolvedTopScope :: ResolvedModule -> [Declaration]
resolvedTopScope = map importedDeclaration . filter isTop . resolvedScope where
	isTop :: ImportedDeclaration -> Bool
	isTop = any (not . importIsQualified) . importedBy

-- | Imported declaration holds info about which imports (there can be many for one declaration) brought it to scope
data ImportedDeclaration = ImportedDeclaration {
	importedBy :: [Import],
	importedDeclaration :: Declaration }

-- | Resolve modules, function is not IO, so all file names must be canonicalized
resolve :: (Traversable t, Foldable t) => Database -> t Module -> t ResolvedModule
resolve db = flip evalState M.empty . flip runReaderT db . runResolveM . traverse resolveModule

-- | Resolve module
resolveModule :: Module -> ResolveM ResolvedModule
resolveModule m = gets (M.lookup $ moduleId m) >>= maybe resolveModule' return where
	resolveModule' = save $ case moduleLocation m of
		CabalModule {} -> return ResolvedModule {
			resolvedModule = m,
			resolvedScope = map (ImportedDeclaration []) (M.elems $ moduleDeclarations m),
			resolvedExports = M.elems (moduleDeclarations m) }
		_ -> do
			scope' <-
				liftM ((thisDecls ++) . mergeImported . concat) .
				mapM (resolveImport m) .
				(import_ (fromString "Prelude") :) .
				moduleImports $ m
			let
				exports' =
					concatMap (exported scope') .
					fromMaybe [] .
					moduleExports $ m
			return $ ResolvedModule m scope' exports'
	thisDecls :: [ImportedDeclaration]
	thisDecls = map (ImportedDeclaration []) $ M.elems $ moduleDeclarations m
	save :: ResolveM ResolvedModule -> ResolveM ResolvedModule
	save act = do
		rm <- act
		modify $ M.insert (moduleId (resolvedModule rm)) rm
		return rm

-- | Select declarations exported with @Export@
exported :: [ImportedDeclaration] -> Export -> [Declaration]
exported ds (ExportName q n) = maybeToList $ importedDeclaration <$> find isExported ds where
	isExported :: ImportedDeclaration -> Bool
	isExported (ImportedDeclaration imps decl') = declarationName decl' == n && case q of
		Nothing -> any (not . importIsQualified) imps
		Just q' -> any ((== q') . importName) imps
exported ds (ExportModule m) =
	map importedDeclaration $
	filter (any (unqualBy m) . importedBy) ds
	where
		unqualBy :: Text -> Import -> Bool
		unqualBy m' i = importName i == m' && not (importIsQualified i)

-- | Bring declarations into scope
resolveImport :: Module -> Import -> ResolveM [ImportedDeclaration]
resolveImport m i = liftM (map $ ImportedDeclaration [i]) resolveImport' where
	resolveImport' :: ResolveM [Declaration]
	resolveImport' = do
		ms <- case moduleLocation m of
			FileModule file proj -> do
				db <- ask
				let
					proj' = proj >>= refineProject db
				case proj' of
					Nothing -> selectImport i [
						inFile $ importedModuleFilePath m file i,
						byCabal]
					Just p -> selectImport i [
						inProject p,
						inDepsOf file p]
			CabalModule cabal _ _ -> selectImport i [inCabal cabal]
			ModuleSource _ -> selectImport i [byCabal]
		liftM (concatMap resolvedExports) $ mapM resolveModule ms
	selectImport :: Import -> [ModuleId -> Bool] -> ResolveM [Module]
	selectImport i' fs = liftM (selectModules (\md -> all ($ moduleId md) (byImport i' : fs))) ask
	byImport :: Import -> ModuleId -> Bool
	byImport i' m' = importModuleName i' == moduleIdName m'
	importedModuleFilePath :: Module -> FilePath -> Import -> FilePath
	importedModuleFilePath m' f' i' =
		(`addExtension` "hs") . joinPath .
		(++ ipath) . reverse . drop (length mpath) .
		reverse $ fpath
		where
			mpath = map T.unpack $ T.split (== '.') $ moduleName m'
			ipath = map T.unpack $ T.split (== '.') $ importModuleName i'
			fpath = splitDirectories $ dropExtension f'
	deps f p = maybe [] infoDepends $ fileTarget p f
	inDepsOf f p m' = any (`inPackage` m') (deps f p)

-- | Merge imported declarations
mergeImported :: [ImportedDeclaration] -> [ImportedDeclaration]
mergeImported =
	map (uncurry ImportedDeclaration .
		(concatMap importedBy &&& importedDeclaration . head)) .
	groupBy ((==) `on` declId) .
	sortBy (comparing declId)
	where
		declId :: ImportedDeclaration -> (Text, Maybe ModuleId)
		declId = importedDeclaration >>> declarationName &&& declarationDefined