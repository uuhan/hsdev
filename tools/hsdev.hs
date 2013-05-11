module Main (
	main
	) where

import Control.Concurrent
import Control.Exception (catch, SomeException)
import Control.Monad
import Control.Monad.Error
import Control.Monad.Trans.Maybe
import Control.Monad.IO.Class
import qualified Data.ByteString.Lazy.Char8 as L (unpack)
import Data.Aeson (encode)
import Data.Either
import Data.Maybe
import Data.Monoid
import Data.List
import qualified Data.Map as M
import qualified Data.Set as S
import System.Args
import System.Environment
import System.Exit
import System.Directory (canonicalizePath, getDirectoryContents, doesFileExist)
import System.FilePath
import System.IO

import HsDev.Cache
import HsDev.Commands
import HsDev.Database
import HsDev.Database.Async
import HsDev.Project
import HsDev.Scan
import HsDev.Symbols
import HsDev.Symbols.Util
import HsDev.Symbols.JSON
import HsDev.Tools.GhcMod
import HsDev.Util

main :: IO ()
main = do
	hSetEncoding stdout utf8
	args' <- getArgs
	case args' of
		["help"] -> printUsage
		[] -> do
			db <- newAsync
			traceEvents db
			run db
		_ -> putStrLn "Unknown command" >> printUsage

commands :: [Command]
commands = [
	cmd "scan" "scan modules installed in cabal" [
		"-cabal [sandbox]" $= "path to sandbox"],
	cmd "scan" "scan project" [
		"-project p" $= "path to project .cabal file"],
	cmd "scan" "scan file" [
		"-file f" $= "file to scan"],
	cmd "scan" "scan module from cabal" [
		"module" $= "module to scan",
		"-cabal [sandbox]" $= "path to sandbox"],
	cmd "find" "find symbol" $ fmtArgs [
		"name" $= "",
		"[-project p]" $= "symbol in project",
		"[-file [f]]" $= "symbol in file",
		"[-module m]" $= "module of symbol",
		"[-cabal [sandbox]]" $= "sandbox of module, where symbol defined"],
	cmd "list" "list modules" [
		"[-cabal [sandbox]]" $= "modules from sandbox",
		"[-project p]" $= "modules from project"],
	cmd "browse" "browse module" $ fmtArgs [
		"module" $= "",
		"[-project p]" $= "module in project",
		"[-cabal [sandbox]]" $= "sandbox of module"],
	cmd "goto" "find symbol declaration" [
		"name" $= "",
		"[-file f]" $= "context source file"],
	cmd "info" "get info for symbol" [
		"name" $= "",
		"[-file f]" $= "context source file"],
	cmd "complete" "autocompletion" $ fmtArgs [
		"input" $= "string to complete",
		"-file file" $= "context source file"],
	cmd "complete" "autocompletion" $ fmtArgs [
		"input" $= "string to complete",
		"-module m" $= "module to complete from",
		"[-cabal [sandbox]]" $= ""],
	cmd "dump" "dump file names, that are loaded in database" ["-files" $= ""],
	cmd "dump" "dump module contents" ["-file f" $= "file to dump"],
	cmd "cache" "dump cache of cabal packages" ["-dump" $= "", "-cabal [sandbox]" $= ""],
	cmd "cache" "dump cache of project" ["-dump" $= "", "-project p" $= ""],
	cmd "cache" "dump all" ["-dump" $= ""],
	cmd "cache" "load cache of cabal packages" ["-load" $= "", "-cabal [sandbox]" $= ""],
	cmd "cache" "load cache of project" ["-load" $= "", "-project p" $= ""],
	cmd "cache" "load cache from file" ["-load" $= "", "-file cache-file" $= ""],
	cmd "cache" "load cache from directory" ["-load" $= "", "-path path" $= ""],
	cmd "help" "this command" [],
	cmd "help" "show help about command" [
		"command" $= "command name"],
	cmd "exit" "exit" []]
	where
		fmtArgs = (++ ["[-format fmt]" $= "output format, can be 'raw' (using print), 'name' for just name of symbol, 'brief' for short info, 'detailed' for detailed info and 'json' for json output"])

run :: Async Database -> IO ()
run db = run' >>= \b -> when (not b) (run db) where
	run' =  flip catch onError $ do
		dbval <- readAsync db
		cmd <- liftM split getLine
		case parseCommand commands cmd of
			Left e -> putStrLn e >> return False
			Right (name, cmdArgs) -> (>> return (name == "exit")) $ case name of
				"exit" -> return ()
				"help" -> void $ runMaybeT $ msum [
					do
						cmdName <- maybe mzero return $ at 0 cmdArgs
						liftIO $ mapM_ print $ filter ((== cmdName) . commandName) commands,
					liftIO printUsage]
				"scan" -> do
					forkAction $ runMaybeT $ msum [
						do
							cabalPath <- MaybeT $ return $ arg "cabal" cmdArgs
							mname <- MaybeT $ return $ at 0 cmdArgs
							lift $ update db $ scanModule (asCabal cabalPath) mname,
						do
							cabalPath <- MaybeT $ return $ arg "cabal" cmdArgs
							ms <- lift $ withConfig (config { configCabal = asCabal cabalPath }) list
							mapM_ (lift . update db . scanModule (asCabal cabalPath)) ms,
							--lift $ update db $ scanCabal (asCabal cabalPath),
						do
							file <- MaybeT $ return $ arg "file" cmdArgs
							lift $ update db $ scanFile file,
						do
							proj <- MaybeT $ return $ arg "project" cmdArgs
							proj' <- liftIO $ locateProject proj
							maybe (throwError $ "Project " ++ proj ++ " not found") (lift . update db . scanProject) proj']
					--maybe (return ()) (modifyAsync db . Append) r
				"find" -> do
					rs <- runAction (findDeclaration dbval (fromJust $ at 0 cmdArgs))
					proj' <- getProject dbval cmdArgs
					file' <- maybe (return Nothing) (\f -> if null f then return Nothing else fmap Just (canonicalizePath f)) $ arg "file" cmdArgs
					let
						filters :: Symbol a -> Bool
						filters = satisfy $ catMaybes [
							fmap inProject proj',
							fmap inFile file',
							if has "file" cmdArgs then Just bySources else Nothing,
							fmap inModule $ arg "module" cmdArgs,
							fmap (inCabal . asCabal) $ arg "cabal" cmdArgs]
						rs' = filter filters rs
					formatResult (fromMaybe "detailed" $ arg "format" cmdArgs) rs'
				"list" -> do
					proj' <- getProject dbval cmdArgs
					let
						filters = satisfy $ catMaybes [
							fmap inProject proj',
							fmap (inCabal . asCabal) $ arg "cabal" cmdArgs]
						ms = filter filters $ concatMap S.toList $ M.elems $ databaseModules dbval
					printModules ms
				"browse" -> do
					rs <- runAction (findModule dbval (fromJust $ at 0 cmdArgs))
					proj' <- getProject dbval cmdArgs
					let
						filters :: Symbol a -> Bool
						filters = satisfy $ catMaybes [
							fmap inProject proj',
							fmap (inCabal . asCabal) $ arg "cabal" cmdArgs]
						rs' = filter filters rs
						browsedModule = head rs'
					fromMaybe (return ()) $ msum [
						if length rs' > 1 then Just (putStrLn "Ambiguous modules:" >> printModules rs') else Nothing,
						if null rs' then Just (putStrLn "Module not found") else Nothing,
						Just $ formatResult (fromMaybe "detailed" $ arg "format" cmdArgs) $ M.elems $ moduleDeclarations $ symbol browsedModule]
				"goto" -> do
					rs <- runAction (goToDeclaration dbval (arg "file" cmdArgs) (fromJust $ at 0 cmdArgs))
					mapM_ print rs
				"info" -> do
					str <- runAction (symbolInfo dbval (arg "file" cmdArgs) (fromJust $ at 0 cmdArgs))
					putStrLn str
				"complete" -> void $ runMaybeT $ do
					m <- msum [
						do
							file <- maybe mzero (liftIO . canonicalizePath) $ arg "file" cmdArgs
							maybe (liftIO (putStrLn "Can't locate file in database") >> mzero) return $ lookupFile file dbval,
						do
							mname <- maybe mzero return $ arg "module" cmdArgs
							cabal <- return $ maybe Cabal asCabal $ arg "cabal" cmdArgs
							maybe (liftIO (putStrLn "Can't find module specified") >> mzero) return $ lookupModule cabal mname dbval]
					rs <- liftIO $ runAction (completions dbval m (fromJust $ at 0 cmdArgs))
					liftIO $ formatResult (fromMaybe "name" $ arg "format" cmdArgs) rs
				"dump" -> void $ runMaybeT $ msum [
					when (has "files" cmdArgs) $ do
						forM_  (M.assocs $ M.map symbolName $ databaseFiles dbval) $ \(fname, mname) ->
							liftIO (putStrLn (mname ++ " in " ++ fname)),
					do
						file <- MaybeT $ return $ arg "file" cmdArgs
						maybe (liftIO $ putStrLn "File not found") (liftIO . print) $ M.lookup file (databaseFiles dbval)]
				"cache" -> do
					db' <- cache cmdArgs dbval
					modifyAsync db (Append db')
				_ -> putStrLn "Unknown command"
		where
			onError :: SomeException -> IO Bool
			onError e = (putStrLn $ "Exception: " ++ show e) >> return False
			formatResult fmt rs = mapM_ (putStrLn . format) rs where
				format = case fmt of
					"raw" -> show
					"name" -> symbolName
					"brief" -> brief
					"detailed" -> detailed
					"json" -> L.unpack . encode . encodeDeclaration
					_ -> show

			printModules ms = mapM_ printModule ms where
				printModule m
					| bySources m = putStrLn $ symbolName m ++ " (" ++ maybe "" locationFile (symbolLocation m) ++ ")"
					| otherwise = putStrLn $ symbolName m ++ maybe "" (\c -> if c == Cabal then "" else show c) (moduleCabal $ symbol m)
			asCabal "" = Cabal
			asCabal p = CabalDev p
			getProject :: Database -> Args String -> IO (Maybe Project)
			getProject db as = do
				projCabal <- maybe (return Nothing) (fmap Just . canonicalizePath) pname
				return $ msum [proj, fmap project projCabal]
				where
					pname = arg "project" as
					proj = find ((== pname) . Just . projectName) $ M.elems $ databaseProjects db

forkAction :: Monoid a => ErrorT String IO a -> IO ()
forkAction act = void $ forkIO $ void $ runAction act

runAction :: Monoid a => ErrorT String IO a -> IO a
runAction act = runErrorT act >>= either onError onOk where
	onError msg = do
		putStrLn $ "Error: " ++ msg
		return mempty
	onOk r = do
		putStrLn "Ok"
		return r

printUsage :: IO ()
printUsage = mapM_ print commands

cache :: Args String -> Database -> IO Database
cache as db
	| has "dump" as = do
		r <- runMaybeT $ msum [cabalSave, projectSave, saveAll]
		maybe (putStrLn "Invalid arguments") (const $ putStrLn "Ok") r
		return mempty
	| has "load" as = do
		r <- runMaybeT $ msum [cabalLoad, projectLoad, loadPath]
		maybe (putStrLn "Invalid arguments" >> return mempty) return r
	| otherwise = putStrLn "Invalid arguments" >> return mempty
	where
		cabalSave = do
			cabal <- cabalArg
			liftIO $ dump (cabalCache cabal) (cabalModules cabal db)
		projectSave = do
			proj <- projectArg
			liftIO $ dump (projectCache proj) (projectModules proj db)
		saveAll = liftIO $ do
			forM_ (M.keys $ databaseCabalModules db) $ \cabal -> dump (cabalCache cabal) (cabalModules cabal db)
			forM_ (M.keys $ databaseProjects db) $ \proj -> dump (projectCache $ project proj) (projectModules (project proj) db)
		cabalLoad = do
			cabal <- cabalArg
			liftIO $ load (cabalCache cabal)
		projectLoad = do
			proj <- projectArg
			liftIO $ load (projectCache proj)
		loadPath = do
			p <- MaybeT $ return $ arg "path" as
			path <- liftIO $ canonicalizePath p
			cts <- liftM (filter ((== ".json") . takeExtension)) $ liftIO $ getDirectoryContents path
			liftM mconcat $ forM cts $ \c -> liftIO $ do
				e <- doesFileExist (path </> c)
				if e then load (path </> c) else return mempty
		cabalArg = do
			c <- MaybeT $ return $ arg "cabal" as
			if null c
				then return Cabal
				else do
					c' <- liftIO $ canonicalizePath c
					return $ CabalDev c'
		projectArg = fmap (project) $ (MaybeT $ return $ arg "project" as) >>= liftIO . canonicalizePath
