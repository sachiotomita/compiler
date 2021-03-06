{-# OPTIONS_GHC -Wno-unused-do-bind #-}
{-# LANGUAGE BangPatterns, OverloadedStrings #-}
module Build
  ( fromExposed
  , fromMains
  , Artifacts(..)
  , Main(..)
  , Module(..)
  , CachedInterface(..)
  )
  where


import Control.Concurrent (forkIO)
import Control.Concurrent.MVar
import Control.Monad (filterM, mapM_, sequence_)
import qualified Data.ByteString as B
import qualified Data.Char as Char
import qualified Data.Either as Either
import qualified Data.Graph as Graph
import qualified Data.List as List
import qualified Data.Map.Utils as Map
import qualified Data.Map.Strict as Map
import Data.Map.Strict ((!))
import qualified Data.Maybe as Maybe
import qualified Data.Name as Name
import qualified Data.NonEmptyList as NE
import qualified Data.OneOrMore as OneOrMore
import qualified Data.Set as Set
import qualified System.Directory as Dir
import qualified System.FilePath as FP
import System.FilePath ((</>), (<.>))

import qualified AST.Source as Src
import qualified AST.Optimized as Opt
import qualified Compile
import qualified Elm.Details as Details
import qualified Elm.Interface as I
import qualified Elm.ModuleName as ModuleName
import qualified Elm.Outline as Outline
import qualified Elm.Package as Pkg
import qualified File
import qualified Parse.Module as Parse
import qualified Reporting
import qualified Reporting.Annotation as A
import qualified Reporting.Error as Error
import qualified Reporting.Error.Syntax as Syntax
import qualified Reporting.Error.Import as Import
import qualified Reporting.Exit as Exit
import qualified Stuff



-- ENVIRONMENT


data Env =
  Env
    { _key :: Reporting.BKey
    , _root :: FilePath
    , _pkg :: Pkg.Name
    , _srcDirs :: [FilePath]
    , _locals :: Map.Map ModuleName.Raw Details.Local
    , _foreigns :: Map.Map ModuleName.Raw Details.Foreign
    }


makeEnv :: Reporting.BKey -> FilePath -> Details.Details -> Env
makeEnv key root (Details.Details _ validOutline locals foreigns _) =
  case validOutline of
    Details.ValidApp (Outline.AppOutline _ srcDirs _ _ _ _) ->
      Env key root Pkg.dummyName (NE.toList srcDirs) locals foreigns

    Details.ValidPkg (Outline.PkgOutline pkg _ _ _ _ _ _ _) _ ->
      Env key root pkg ["src"] locals foreigns



-- FORK


fork :: IO a -> IO (MVar a)
fork work =
  do  mvar <- newEmptyMVar
      _ <- forkIO $ putMVar mvar =<< work
      return mvar


{-# INLINE forkWithKey #-}
forkWithKey :: (k -> a -> IO b) -> Map.Map k a -> IO (Map.Map k (MVar b))
forkWithKey func dict =
  Map.traverseWithKey (\k v -> fork (func k v)) dict



-- FROM EXPOSED


fromExposed :: Reporting.Style -> FilePath -> Details.Details -> NE.List ModuleName.Raw -> IO (Either Exit.BuildProblem ())
fromExposed style root details (NE.List e es) =
  Reporting.trackBuild style $ \key ->
  do  let env = makeEnv key root details
      dmvar <- Details.loadInterfaces root details

      -- crawl
      mvar <- newEmptyMVar
      roots <- Map.fromKeysA (fork . crawlModule env mvar) (e:es)
      putMVar mvar roots
      mapM_ readMVar roots
      statuses <- traverse readMVar =<< readMVar mvar

      -- compile
      midpoint <- checkExposedMidpoint dmvar statuses
      case midpoint of
        Left problem ->
          return (Left (Exit.BuildProjectProblem problem))

        Right foreigns ->
          do  rmvar <- newEmptyMVar
              resultMVars <- forkWithKey (checkModule env foreigns rmvar) statuses
              putMVar rmvar resultMVars
              results <- traverse readMVar resultMVars
              writeDetails root details results
              return (detectProblems results) -- TODO error if "exposed-modules" are not found



-- FROM MAINS


data Artifacts =
  Artifacts
    { _name :: Pkg.Name
    , _deps :: Dependencies
    , _mains :: NE.List Main
    , _modules :: [Module]
    }


data Module
  = Fresh ModuleName.Raw I.Interface Opt.LocalGraph
  | Cached ModuleName.Raw Bool (MVar CachedInterface)


type Dependencies =
  Map.Map ModuleName.Canonical I.DependencyInterface


fromMains :: Reporting.Style -> FilePath -> Details.Details -> NE.List FilePath -> IO (Either Exit.BuildProblem Artifacts)
fromMains style root details paths =
  Reporting.trackBuild style $ \key ->
  do  let env = makeEnv key root details

      elmains <- findMains env paths
      case elmains of
        Left problem ->
          return (Left (Exit.BuildProjectProblem problem))

        Right lmains ->
          do  -- crawl
              dmvar <- Details.loadInterfaces root details
              smvar <- newMVar Map.empty
              smainMVars <- traverse (fork . crawlMain env smvar) lmains
              smains <- traverse readMVar smainMVars
              statuses <- traverse readMVar =<< readMVar smvar

              midpoint <- checkMainsMidpoint dmvar statuses smains
              case midpoint of
                Left problem ->
                  return (Left (Exit.BuildProjectProblem problem))

                Right foreigns ->
                  do  -- compile
                      rmvar <- newEmptyMVar
                      resultsMVars <- forkWithKey (checkModule env foreigns rmvar) statuses
                      putMVar rmvar resultsMVars
                      rmainMVars <- traverse (fork . checkMain env resultsMVars) smains
                      results <- traverse readMVar resultsMVars
                      writeDetails root details results
                      toArtifacts env foreigns results <$> traverse readMVar rmainMVars



-- CRAWL


type StatusDict =
  Map.Map ModuleName.Raw (MVar Status)


data Status
  = SCached Details.Local
  | SChanged Details.Local B.ByteString Src.Module
  | SBadImport Import.Problem
  | SBadSyntax FilePath File.Time B.ByteString Syntax.Error
  | SForeign Pkg.Name
  | SKernel


crawlDeps :: Env -> MVar StatusDict -> [ModuleName.Raw] -> a -> IO a
crawlDeps env mvar deps blockedValue =
  do  statusDict <- takeMVar mvar
      let depsDict = Map.fromKeys (\_ -> ()) deps
      let newsDict = Map.difference depsDict statusDict
      statuses <- Map.traverseWithKey crawlNew newsDict
      putMVar mvar (Map.union statuses statusDict)
      mapM_ readMVar statuses
      return blockedValue
  where
    crawlNew name () = fork (crawlModule env mvar name)


crawlModule :: Env -> MVar StatusDict -> ModuleName.Raw -> IO Status
crawlModule env@(Env _ root pkg srcDirs locals foreigns) mvar name =
  do  let fileName = ModuleName.toFilePath name <.> "elm"
      let inRoot path = File.exists (root </> path)

      paths <- filterM inRoot (map (</> fileName) srcDirs)

      case paths of
        [path] ->
          case Map.lookup name foreigns of
            Just (Details.Foreign dep deps) ->
              return $ SBadImport $ Import.Ambiguous path [] dep deps

            Nothing ->
              case Map.lookup name locals of
                Nothing ->
                  crawlFile env mvar name path

                Just local@(Details.Local oldPath oldTime deps _) ->
                  if path /= oldPath
                  then crawlFile env mvar name path
                  else
                    do  newTime <- File.getTime path
                        if oldTime < newTime
                          then crawlFile env mvar name path
                          else crawlDeps env mvar deps (SCached local)

        p1:p2:ps ->
          return $ SBadImport $ Import.AmbiguousLocal p1 p2 ps

        [] ->
          case Map.lookup name foreigns of
            Just (Details.Foreign dep deps) ->
              case deps of
                [] ->
                  return $ SForeign dep

                d:ds ->
                  return $ SBadImport $ Import.AmbiguousForeign dep d ds

            Nothing ->
              if Name.isKernel name && Pkg.isKernel pkg then
                do  exists <- File.exists ("src" </> ModuleName.toFilePath name <.> "js")
                    return $ if exists then SKernel else SBadImport Import.NotFound
              else
                return $ SBadImport Import.NotFound


crawlFile :: Env -> MVar StatusDict -> ModuleName.Raw -> FilePath -> IO Status
crawlFile env@(Env _ root pkg _ _ _) mvar expectedName path =
  do  time <- File.getTime path
      source <- File.readUtf8 (root </> path)

      case Parse.fromByteString pkg source of
        Left err ->
          return $ SBadSyntax path time source err

        Right modul@(Src.Module maybeActualName _ imports values _ _ _ _) ->
          case maybeActualName of
            Nothing ->
              return $ SBadSyntax path time source (Syntax.ModuleNameUnspecified expectedName)

            Just name@(A.At _ actualName) ->
              if expectedName == actualName then
                let
                  deps = map Src.getImportName imports
                  local = Details.Local path time deps (any isMain values)
                in
                crawlDeps env mvar deps (SChanged local source modul)
              else
                return $ SBadSyntax path time source (Syntax.ModuleNameMismatch expectedName name)


isMain :: A.Located Src.Value -> Bool
isMain (A.At _ (Src.Value (A.At _ name) _ _ _)) =
  name == Name.main



-- CHECK MODULE


type ResultDict =
  Map.Map ModuleName.Raw (MVar Result)


data Result
  = RNew Details.Local I.Interface Opt.LocalGraph
  | RSame Details.Local I.Interface Opt.LocalGraph
  | RCached Bool (MVar CachedInterface)
  | RNotFound Import.Problem
  | RProblem Error.Module
  | RBlocked
  | RForeign I.Interface
  | RKernel


data CachedInterface
  = Unneeded
  | Loaded I.Interface
  | Corrupted


checkModule :: Env -> Dependencies -> MVar ResultDict -> ModuleName.Raw -> Status -> IO Result
checkModule env@(Env _ root pkg _ _ _) foreigns resultsMVar name status =
  case status of
    SCached local@(Details.Local path time deps hasMain) ->
      do  results <- readMVar resultsMVar
          depsStatus <- checkDeps root results deps
          case depsStatus of
            DepsChange ifaces ->
              do  source <- File.readUtf8 path
                  case Parse.fromByteString pkg source of
                    Right modul -> compile env local source ifaces modul
                    Left err ->
                      return $ RProblem $
                        Error.Module name path time source (Error.BadSyntax err)

            DepsSame _ _ ->
              do  mvar <- newMVar Unneeded
                  return (RCached hasMain mvar)

            DepsBlock ->
              return RBlocked

            DepsNotFound problems ->
              do  source <- File.readUtf8 path
                  return $ RProblem $ Error.Module name path time source $
                    case Parse.fromByteString pkg source of
                      Right (Src.Module _ _ imports _ _ _ _ _) ->
                         Error.BadImports (toImportErrors env results imports problems)

                      Left err ->
                        Error.BadSyntax err

    SChanged local@(Details.Local path time deps _) source modul@(Src.Module _ _ imports _ _ _ _ _) ->
      do  results <- readMVar resultsMVar
          depsStatus <- checkDeps root results deps
          case depsStatus of
            DepsChange ifaces ->
              compile env local source ifaces modul

            DepsSame same cached ->
              do  maybeLoaded <- checkCachedInterfaces root cached
                  case maybeLoaded of
                    Nothing ->
                      return RBlocked

                    Just loaded ->
                      do  let ifaces = Map.union loaded (Map.fromList same)
                          compile env local source ifaces modul

            DepsBlock ->
              return RBlocked

            DepsNotFound problems ->
              return $ RProblem $ Error.Module name path time source $
                Error.BadImports (toImportErrors env results imports problems)

    SBadImport importProblem ->
      return (RNotFound importProblem)

    SBadSyntax path time source err ->
      return $ RProblem $ Error.Module name path time source $
        Error.BadSyntax err

    SForeign home ->
      case foreigns ! ModuleName.Canonical home name of
        I.Public iface -> return (RForeign iface)
        I.Private _ _ _ -> error "loading private interface in Build"

    SKernel ->
      return RKernel



-- CHECK DEPS


data DepsStatus
  = DepsChange (Map.Map ModuleName.Raw I.Interface)
  | DepsSame [Dep] [CDep]
  | DepsBlock
  | DepsNotFound (NE.List (ModuleName.Raw, Import.Problem))


checkDeps :: FilePath -> ResultDict -> [ModuleName.Raw] -> IO DepsStatus
checkDeps root results deps =
  checkDepsHelp root results deps [] [] [] [] False


type Dep = (ModuleName.Raw, I.Interface)
type CDep = (ModuleName.Raw, MVar CachedInterface)


checkDepsHelp :: FilePath -> ResultDict -> [ModuleName.Raw] -> [Dep] -> [Dep] -> [CDep] -> [(ModuleName.Raw,Import.Problem)] -> Bool -> IO DepsStatus
checkDepsHelp root results deps new same cached importProblems isBlocked =
  case deps of
    dep:otherDeps ->
      do  result <- readMVar (results ! dep)
          case result of
            RNew _ iface _  -> checkDepsHelp root results otherDeps ((dep,iface) : new) same cached importProblems isBlocked
            RSame _ iface _ -> checkDepsHelp root results otherDeps new ((dep,iface) : same) cached importProblems isBlocked
            RCached _ mvar  -> checkDepsHelp root results otherDeps new same ((dep,mvar) : cached) importProblems isBlocked
            RNotFound prob  -> checkDepsHelp root results otherDeps new same cached ((dep,prob) : importProblems) True
            RProblem _      -> checkDepsHelp root results otherDeps new same cached importProblems True
            RBlocked        -> checkDepsHelp root results otherDeps new same cached importProblems True
            RForeign iface  -> checkDepsHelp root results otherDeps new ((dep,iface) : same) cached importProblems isBlocked
            RKernel         -> checkDepsHelp root results otherDeps new same cached importProblems isBlocked

    [] ->
      case importProblems of
        p:ps ->
          return $ DepsNotFound (NE.List p ps)

        [] ->
          if isBlocked then
            return $ DepsBlock

          else if null new then
            return $ DepsSame same cached

          else
            do  maybeLoaded <- checkCachedInterfaces root cached
                case maybeLoaded of
                  Nothing ->
                    return DepsBlock

                  Just loaded ->
                    return $ DepsChange $
                      Map.union loaded (Map.union (Map.fromList new) (Map.fromList same))



-- TO IMPORT ERROR


toImportErrors :: Env -> ResultDict -> [Src.Import] -> NE.List (ModuleName.Raw, Import.Problem) -> NE.List Import.Error
toImportErrors (Env _ _ _ _ locals foreigns) results imports problems =
  let
    knownModules =
      Set.unions
        [ Map.keysSet foreigns
        , Map.keysSet locals
        , Map.keysSet results
        ]

    unimportedModules =
      Set.difference knownModules (Set.fromList (map Src.getImportName imports))

    regionDict =
      Map.fromList (map (\(Src.Import (A.At region name) _ _) -> (name, region)) imports)

    toError (name, problem) =
      Import.Error (regionDict ! name) name unimportedModules problem
  in
  fmap toError problems



-- CACHED INTERFACE


checkCachedInterfaces :: FilePath -> [(ModuleName.Raw, MVar CachedInterface)] -> IO (Maybe (Map.Map ModuleName.Raw I.Interface))
checkCachedInterfaces root deps =
  do  loading <- traverse (fork . checkCache root) deps
      loaded <- traverse readMVar loading
      return $ Map.fromList <$> sequence loaded


checkCache :: FilePath -> (ModuleName.Raw, MVar CachedInterface) -> IO (Maybe Dep)
checkCache root (name, ciMvar) =
  do  cachedInterface <- takeMVar ciMvar
      case cachedInterface of
        Corrupted ->
          do  putMVar ciMvar cachedInterface
              return Nothing

        Loaded iface ->
          do  putMVar ciMvar cachedInterface
              return (Just (name, iface))

        Unneeded ->
          do  maybeIface <- File.readBinary (Stuff.elmi root name)
              case maybeIface of
                Nothing ->
                  do  putMVar ciMvar Corrupted
                      return Nothing

                Just iface ->
                  do  putMVar ciMvar (Loaded iface)
                      return (Just (name, iface))



-- CHECK PROJECT


checkExposedMidpoint :: MVar (Maybe Dependencies) -> Map.Map ModuleName.Raw Status -> IO (Either Exit.BuildProjectProblem Dependencies)
checkExposedMidpoint dmvar statuses =
  case checkForCycles statuses of
    Nothing ->
      do  maybeForeigns <- readMVar dmvar
          case maybeForeigns of
            Nothing -> return (Left Exit.BP_CannotLoadDependencies)
            Just fs -> return (Right fs)

    Just (NE.List name names) ->
      do  _ <- readMVar dmvar
          return (Left (Exit.BP_Cycle name names))


checkMainsMidpoint :: MVar (Maybe Dependencies) -> Map.Map ModuleName.Raw Status -> NE.List MainStatus -> IO (Either Exit.BuildProjectProblem Dependencies)
checkMainsMidpoint dmvar statuses smains =
  case checkForCycles statuses of
    Nothing ->
      case checkUniqueMains statuses smains of
        Nothing ->
          do  maybeForeigns <- readMVar dmvar
              case maybeForeigns of
                Nothing -> return (Left Exit.BP_CannotLoadDependencies)
                Just fs -> return (Right fs)

        Just problem ->
          do  _ <- readMVar dmvar
              return (Left problem)

    Just (NE.List name names) ->
      do  _ <- readMVar dmvar
          return (Left (Exit.BP_Cycle name names))



-- CHECK FOR CYCLES


checkForCycles :: Map.Map ModuleName.Raw Status -> Maybe (NE.List ModuleName.Raw)
checkForCycles modules =
  let
    !graph = Map.foldrWithKey addToGraph [] modules
    !sccs = Graph.stronglyConnComp graph
  in
  checkForCyclesHelp sccs


checkForCyclesHelp :: [Graph.SCC ModuleName.Raw] -> Maybe (NE.List ModuleName.Raw)
checkForCyclesHelp sccs =
  case sccs of
    [] ->
      Nothing

    scc:otherSccs ->
      case scc of
        Graph.AcyclicSCC _     -> checkForCyclesHelp otherSccs
        Graph.CyclicSCC []     -> checkForCyclesHelp otherSccs
        Graph.CyclicSCC (m:ms) -> Just (NE.List m ms)


type Node =
  ( ModuleName.Raw, ModuleName.Raw, [ModuleName.Raw] )


addToGraph :: ModuleName.Raw -> Status -> [Node] -> [Node]
addToGraph name status graph =
  let
    dependencies =
      case status of
        SCached  (Details.Local _ _ deps _)     -> deps
        SChanged (Details.Local _ _ deps _) _ _ -> deps
        SBadImport _                            -> []
        SBadSyntax _ _ _ _                      -> []
        SForeign _                              -> []
        SKernel                                 -> []
  in
  (name, name, dependencies) : graph



-- CHECK UNIQUE MAINS


checkUniqueMains :: Map.Map ModuleName.Raw Status -> NE.List MainStatus -> Maybe Exit.BuildProjectProblem
checkUniqueMains insides smains =
  let
    outsidesDict =
      Map.fromListWith OneOrMore.more (Maybe.mapMaybe mainStatusToNamePathPair (NE.toList smains))
  in
  case Map.traverseWithKey checkOutside outsidesDict of
    Left problem ->
      Just problem

    Right outsides ->
      case sequence_ (Map.intersectionWithKey checkInside outsides insides) of
        Right ()     -> Nothing
        Left problem -> Just problem


mainStatusToNamePathPair :: MainStatus -> Maybe (ModuleName.Raw, OneOrMore.OneOrMore FilePath)
mainStatusToNamePathPair smain =
  case smain of
    SInside _                                     -> Nothing
    SOutsideOk (Details.Local path _ _ _) _ modul -> Just (Src.getName modul, OneOrMore.one path)
    SOutsideErr _                                 -> Nothing


checkOutside :: ModuleName.Raw -> OneOrMore.OneOrMore FilePath -> Either Exit.BuildProjectProblem FilePath
checkOutside name paths =
  case OneOrMore.destruct NE.List paths of
    NE.List p  []     -> Right p
    NE.List p1 (p2:_) -> Left (Exit.BP_MainNameDuplicate name p1 p2)


checkInside :: ModuleName.Raw -> FilePath -> Status -> Either Exit.BuildProjectProblem ()
checkInside name p1 status =
  case status of
    SCached  (Details.Local p2 _ _ _)     -> Left (Exit.BP_MainNameDuplicate name p1 p2)
    SChanged (Details.Local p2 _ _ _) _ _ -> Left (Exit.BP_MainNameDuplicate name p1 p2)
    SBadImport _                          -> Right ()
    SBadSyntax _ _ _ _                    -> Right ()
    SForeign _                            -> Right ()
    SKernel                               -> Right ()



-- COMPILE MODULE


compile :: Env -> Details.Local -> B.ByteString -> Map.Map ModuleName.Raw I.Interface -> Src.Module -> IO Result
compile (Env key root pkg _ _ _) local@(Details.Local path time _ _) source ifaces modul =
  case Compile.compile pkg ifaces modul of
    Right (Compile.Artifacts canonical annotations objects) ->
      do  let name = Src.getName modul
          let iface = I.fromModule pkg canonical annotations
          File.writeBinary (Stuff.elmo root name) objects
          maybeOldi <- File.readBinary (Stuff.elmi root name)
          case maybeOldi of
            Just oldi | oldi == iface ->
              do  -- iface should be fully forced by equality check
                  Reporting.report key Reporting.BDone
                  return (RSame local iface objects)

            _ ->
              do  -- iface may be lazy still
                  -- TODO try adding forkIO here
                  File.writeBinary (Stuff.elmi root name) iface
                  Reporting.report key Reporting.BDone
                  return (RNew local iface objects)

    Left err ->
      do  Reporting.report key Reporting.BDone
          return $ RProblem $
            Error.Module (Src.getName modul) path time source err



-- WRITE DETAILS


writeDetails :: FilePath -> Details.Details -> Map.Map ModuleName.Raw Result -> IO ()
writeDetails root (Details.Details time outline locals foreigns extras) results =
  File.writeBinary (Stuff.details root) $
    Details.Details time outline (Map.foldrWithKey addNewLocal locals results) foreigns extras


addNewLocal :: ModuleName.Raw -> Result -> Map.Map ModuleName.Raw Details.Local -> Map.Map ModuleName.Raw Details.Local
addNewLocal name result locals =
  case result of
    RNew  local _ _ -> Map.insert name local locals
    RSame local _ _ -> Map.insert name local locals
    RCached _ _     -> locals
    RNotFound _     -> locals
    RProblem _      -> locals
    RBlocked        -> locals
    RForeign _      -> locals
    RKernel         -> locals



-- DETECT PROBLEMS


detectProblems :: Map.Map ModuleName.Raw Result -> Either Exit.BuildProblem ()
detectProblems results =
  case Map.foldr addErrors [] results of
    []   -> Right ()
    e:es -> Left (Exit.BuildModuleProblems e es)


addErrors :: Result -> [Error.Module] -> [Error.Module]
addErrors result errors =
  case result of
    RNew  _ _ _ ->   errors
    RSame _ _ _ ->   errors
    RCached _ _ ->   errors
    RNotFound _ ->   errors
    RProblem e  -> e:errors
    RBlocked    ->   errors
    RForeign _  ->   errors
    RKernel     ->   errors



--------------------------------------------------------------------------------
--------------------------------------------------------------------------------
------ AFTER THIS, EVERYTHING IS ABOUT HANDLING MODULES GIVEN BY FILEPATH ------
--------------------------------------------------------------------------------
--------------------------------------------------------------------------------



-- FIND MAIN


data MainLocation
  = LInside ModuleName.Raw
  | LOutside FilePath


findMains :: Env -> NE.List FilePath -> IO (Either Exit.BuildProjectProblem (NE.List MainLocation))
findMains env paths =
  do  mvars <- traverse (fork . findLocation env) paths
      elocs <- traverse readMVar mvars
      return $ checkLocations =<< sequence elocs


checkLocations :: NE.List Location -> Either Exit.BuildProjectProblem (NE.List MainLocation)
checkLocations locations =
  let
    toOneOrMore loc@(Location absolute _ _) =
      (absolute, OneOrMore.one loc)

    fromOneOrMore loc locs =
      case locs of
        [] -> Right ()
        loc2:_ -> Left (Exit.BP_MainPathDuplicate (_relative loc) (_relative loc2))
  in
  fmap (\_ -> fmap _location locations) $
    traverse (OneOrMore.destruct fromOneOrMore) $
      Map.fromListWith OneOrMore.more $ map toOneOrMore (NE.toList locations)



-- LOCATIONS


data Location =
  Location
    { _absolute :: FilePath
    , _relative :: FilePath
    , _location :: MainLocation
    }


findLocation :: Env -> FilePath -> IO (Either Exit.BuildProjectProblem Location)
findLocation env path =
  do  exists <- File.exists path
      if exists
        then isInsideSrcDirs env path <$> Dir.canonicalizePath path
        else return (Left (Exit.BP_PathUnknown path))


isInsideSrcDirs :: Env -> FilePath -> FilePath -> Either Exit.BuildProjectProblem Location
isInsideSrcDirs (Env _ root _ srcDirs _ _) path absolutePath =
  let
    (dirs, file) = FP.splitFileName absolutePath
    (final, ext) = break (=='.') file
  in
  if ext /= ".elm"
  then Left (Exit.BP_WithBadExtension path)
  else
    let
      roots = FP.splitDirectories root
      segments = FP.splitDirectories dirs ++ [final]
    in
    case dropPrefix roots segments of
      Nothing ->
        Right (Location absolutePath path (LOutside path))

      Just relativeSegments ->
        let
          (exits, maybes) =
            Either.partitionEithers (map (isInsideSrcDirsHelp relativeSegments) srcDirs)
        in
        -- TODO make sure this is all correct
        case (exits, Maybe.catMaybes maybes) of
          (_, [(_,name)])      -> Right (Location absolutePath path (LInside name))
          ([], [])             -> Right (Location absolutePath path (LOutside path))
          (_, (s1,_):(s2,_):_) -> Left (Exit.BP_WithAmbiguousSrcDir s1 s2)
          (exit:_, _)          -> Left exit


isInsideSrcDirsHelp :: [String] -> FilePath -> Either Exit.BuildProjectProblem (Maybe (FilePath, ModuleName.Raw))
isInsideSrcDirsHelp segments srcDir =
  case dropPrefix (FP.splitDirectories srcDir) segments of
    Nothing ->
      Right Nothing

    Just names ->
      if all isGoodName names
      then Right (Just (srcDir, Name.fromChars (List.intercalate "." names)))
      else Left (error "Exit.MakeWithInvalidModuleName" srcDir segments)


isGoodName :: [Char] -> Bool
isGoodName name =
  case name of
    [] ->
      False

    char:chars ->
      Char.isUpper char && all (\c -> Char.isAlphaNum c || c == '_') chars


dropPrefix :: [FilePath] -> [FilePath] -> Maybe [FilePath]
dropPrefix roots paths =
  case roots of
    [] ->
      Just paths

    r:rs ->
      case paths of
        [] -> Nothing
        p:ps -> if r == p then dropPrefix rs ps else Nothing



-- CRAWL MAINS


data MainStatus
  = SInside ModuleName.Raw
  | SOutsideOk Details.Local B.ByteString Src.Module
  | SOutsideErr Error.Module


crawlMain :: Env -> MVar StatusDict -> MainLocation -> IO MainStatus
crawlMain env@(Env _ _ pkg _ _ _) mvar given =
  case given of
    LInside name ->
      do  statusMVar <- newEmptyMVar
          statusDict <- takeMVar mvar
          putMVar mvar (Map.insert name statusMVar statusDict)
          putMVar statusMVar =<< crawlModule env mvar name
          return (SInside name)

    LOutside path ->
      do  time <- File.getTime path
          source <- File.readUtf8 path
          case Parse.fromByteString pkg source of
            Right modul@(Src.Module _ _ imports values _ _ _ _) ->
              do  let deps = map Src.getImportName imports
                  let local = Details.Local path time deps (any isMain values)
                  crawlDeps env mvar deps (SOutsideOk local source modul)

            Left syntaxError ->
              return $ SOutsideErr $
                Error.Module "???" path time source (Error.BadSyntax syntaxError)



-- CHECK MAINS


data MainResult
  = RInside ModuleName.Raw
  | ROutsideOk ModuleName.Raw I.Interface Opt.LocalGraph
  | ROutsideErr Error.Module
  | ROutsideBlocked


checkMain :: Env -> ResultDict -> MainStatus -> IO MainResult
checkMain env@(Env _ root _ _ _ _) results pendingMain =
  case pendingMain of
    SInside name ->
      return (RInside name)

    SOutsideErr err ->
      return (ROutsideErr err)

    SOutsideOk local@(Details.Local path time deps _) source modul@(Src.Module _ _ imports _ _ _ _ _) ->
      do  depsStatus <- checkDeps root results deps
          case depsStatus of
            DepsChange ifaces ->
              return $ compileOutside env local source ifaces modul

            DepsSame same cached ->
              do  maybeLoaded <- checkCachedInterfaces root cached
                  case maybeLoaded of
                    Nothing ->
                      return ROutsideBlocked

                    Just loaded ->
                      do  let ifaces = Map.union loaded (Map.fromList same)
                          return $ compileOutside env local source ifaces modul

            DepsBlock ->
              return ROutsideBlocked

            DepsNotFound problems ->
              return $ ROutsideErr $ Error.Module (Src.getName modul) path time source $
                  Error.BadImports (toImportErrors env results imports problems)


compileOutside :: Env -> Details.Local -> B.ByteString -> Map.Map ModuleName.Raw I.Interface -> Src.Module -> MainResult
compileOutside (Env _ _ pkg _ _ _) (Details.Local path time _ _) source ifaces modul =
  let
    name = Src.getName modul
  in
  case Compile.compile pkg ifaces modul of
    Right (Compile.Artifacts canonical annotations objects) ->
      ROutsideOk name (I.fromModule pkg canonical annotations) objects

    Left errors ->
      ROutsideErr $
        Error.Module name path time source errors



-- TO ARTIFACTS


data Main
  = Inside ModuleName.Raw
  | Outside ModuleName.Raw I.Interface Opt.LocalGraph


toArtifacts :: Env -> Dependencies -> Map.Map ModuleName.Raw Result -> NE.List MainResult -> Either Exit.BuildProblem Artifacts
toArtifacts (Env _ _ pkg _ _ _) foreigns results mainResults =
  case gatherProblemsOrMains results mainResults of
    Left (NE.List e es) ->
      Left (Exit.BuildModuleProblems e es)

    Right mains ->
      Right $ Artifacts pkg foreigns mains $
        Map.foldrWithKey addInside (foldr addOutside [] mainResults) results


gatherProblemsOrMains :: Map.Map ModuleName.Raw Result -> NE.List MainResult -> Either (NE.List Error.Module) (NE.List Main)
gatherProblemsOrMains results (NE.List mainResult mainResults) =
  let
    sortMain result (es, mains) =
      case result of
        RInside n        -> (  es, Inside n      : mains)
        ROutsideOk n i o -> (  es, Outside n i o : mains)
        ROutsideErr e    -> (e:es,                 mains)
        ROutsideBlocked  -> (  es,                 mains)

    errors = Map.foldr addErrors [] results
  in
  case (mainResult, foldr sortMain (errors, []) mainResults) of
    (RInside n       , (  [], ms)) -> Right (NE.List (Inside n) ms)
    (RInside _       , (e:es, _ )) -> Left  (NE.List e es)
    (ROutsideOk n i o, (  [], ms)) -> Right (NE.List (Outside n i o) ms)
    (ROutsideOk _ _ _, (e:es, _ )) -> Left  (NE.List e es)
    (ROutsideErr e   , (  es, _ )) -> Left  (NE.List e es)
    (ROutsideBlocked , (  [], _ )) -> error "seems like elm-stuff/ is corrupted"
    (ROutsideBlocked , (e:es, _ )) -> Left  (NE.List e es)


addInside :: ModuleName.Raw -> Result -> [Module] -> [Module]
addInside name result modules =
  case result of
    RNew  _ iface objs -> Fresh name iface objs : modules
    RSame _ iface objs -> Fresh name iface objs : modules
    RCached main mvar  -> Cached name main mvar : modules
    RNotFound _        -> error (badInside name)
    RProblem _         -> error (badInside name)
    RBlocked           -> error (badInside name)
    RForeign _         -> modules
    RKernel            -> modules


badInside :: ModuleName.Raw -> [Char]
badInside name =
  "Error from `" ++ Name.toChars name ++ "` should have been reported already."


addOutside :: MainResult -> [Module] -> [Module]
addOutside main modules =
  case main of
    RInside _                  -> modules
    ROutsideOk name iface objs -> Fresh name iface objs : modules
    ROutsideErr _              -> modules
    ROutsideBlocked            -> modules
