{-# LANGUAGE GADTs,
             DataKinds,
             TypeOperators,
             RankNTypes,
             BangPatterns,
             FlexibleInstances,
             MagicHash,
             UnboxedTuples,
             TemplateHaskell,
             PolyKinds,
             KindSignatures,
             ScopedTypeVariables,
             GeneralizedNewtypeDeriving,
             FlexibleContexts,
             RecordWildCards,
             ConstraintKinds,
             CPP,
             ImplicitParams,
             TypeFamilies #-}
module Machine where

import MachineOps
import Input                      (PreparedInput(..), Rep, Unboxed, OffWith, UnpackedLazyByteString)
import Indexed                    (IFunctor3, Free3(Op3), Void3, Const3(..), imap3, absurd, fold3)
import Utils                      (WQ(..), code, (>*<), Code)
import Data.Word                  (Word64)
import Control.Monad              (forM, join, liftM2)
import Control.Monad.ST           (ST)
import Control.Monad.Reader       (ask, asks, local, Reader, runReader, MonadReader)
import Control.Exception          (Exception, throw)
import Data.STRef                 (STRef)
import Data.STRef.Unboxed         (STRefU)
import Data.Map.Strict            (Map)
import Data.Dependent.Map         (DMap, DSum(..))
import Data.GADT.Compare          (GEq, GCompare, gcompare, geq, (:~:)(Refl), GOrdering(..))
import Safe.Coerce                (coerce)
import Debug.Trace                (trace)
import System.Console.Pretty      (color, Color(Green, White, Red, Blue))
import Data.Text                  (Text)
import Data.Void                  (Void)
import Data.Functor.Const         (Const(..), getConst)
import Data.List                  (intercalate)
import Language.Haskell.TH        (runQ, Q, newName, Name)
import Language.Haskell.TH.Syntax (unTypeQ, unsafeTExpCoerce, Exp(VarE, LetE), Dec(FunD), Clause(Clause), Body(NormalB))
import qualified Data.Map.Strict    as Map  ((!), insert, empty)
import qualified Data.Dependent.Map as DMap ((!), insert, empty, lookup, map, toList, traverseWithKey)

#define inputInstances(derivation) \
derivation(Int)                    \
derivation((OffWith s))            \
derivation(UnpackedLazyByteString) \
derivation(Text)

newtype Machine o a = Machine { getMachine :: Free3 (M o) Void3 '[] Void a }
newtype ΣVar (a :: *) = ΣVar IΣVar
newtype MVar (a :: *) = MVar IMVar
newtype ΦVar (a :: *) = ΦVar IΦVar
type ΦDecl k x xs r a = (ΦVar x, k (x ': xs) r a)
newtype LetBinding o a x = LetBinding (Free3 (M o) Void3 '[] x a)
instance Show (LetBinding o a x) where show (LetBinding m) = show m

data M o k xs r a where
  Halt      :: M o k '[a] Void a
  Ret       :: M o k '[x] x a
  Push      :: WQ x -> k (x ': xs) r a -> M o k xs r a
  Pop       :: k xs r a -> M o k (x ': xs) r a
  Lift2     :: WQ (x -> y -> z) -> k (z ': xs) r a -> M o k (y ': x ': xs) r a
  Sat       :: WQ (Char -> Bool) -> k (Char ': xs) r a -> M o k xs r a
  Call      :: MVar x -> k (x ': xs) r a -> M o k xs r a
  Jump      :: MVar x -> M o k '[] x a
  Empt      :: M o k xs r a
  Commit    :: Bool -> k xs r a -> M o k xs r a
  HardFork  :: k xs r a -> k xs r a -> Maybe (ΦDecl k x xs r a) -> M o k xs r a              --TODO: Deprecate
  SoftFork  :: Maybe Int -> k xs r a -> k xs r a -> Maybe (ΦDecl k x xs r a) -> M o k xs r a --TODO: Deprecate
  Join      :: ΦVar x -> M o k (x ': xs) r a
  Attempt   :: Maybe Int -> k xs r a -> M o k xs r a                                         --TODO: Deprecate
  Tell      :: k (o ': xs) r a -> M o k xs r a
  Seek      :: k xs r a -> M o k (o ': xs) r a
  Case      :: k (x ': xs) r a -> k (y ': xs) r a -> Maybe (ΦDecl k z xs r a) -> M o k (Either x y ': xs) r a
  Choices   :: [WQ (x -> Bool)] -> [k xs r a] -> k xs r a -> Maybe (ΦDecl k y xs r a) -> M o k (x ': xs) r a
  ChainIter :: ΣVar x -> MVar x -> M o k '[] x a
  ChainInit :: ΣVar x -> k '[] x a -> MVar x -> k xs r a -> M o k xs r a
  Swap      :: k (x ': y ': xs) r a -> M o k (y ': x ': xs) r a
  Make      :: ΣVar x -> k xs r a -> M o k (x ': xs) r a
  Get       :: ΣVar x -> k (x ': xs) r a -> M o k xs r a
  Put       :: ΣVar x -> k xs r a -> M o k (x ': xs) r a
  LogEnter  :: String -> k xs r a -> M o k xs r a
  LogExit   :: String -> k xs r a -> M o k xs r a

_App :: Free3 (M o) f (y ': xs) r a -> M o (Free3 (M o) f) (x ': (x -> y) ': xs) r a
_App !m = Lift2 (code ($)) m

_Fmap :: WQ (x -> y) -> Free3 (M o) f (y ': xs) r a -> M o (Free3 (M o) f) (x ': xs) r a
_Fmap !f !m = Push f (Op3 (Lift2 ([flip (code ($))]) m))

_Modify :: ΣVar x -> Free3 (M o) f xs r a -> M o (Free3 (M o) f) ((x -> x) ': xs) r a
_Modify !σ !m = Get σ (Op3 (_App (Op3 (Put σ m))))

{- A key property of the pure semantics of the machine states that
    at the end of the execution of a machine, all the stacks shall
    be empty. This also holds true of any recursive machines, for
    obvious reasons. In the concrete machine, however, it is not
    entirely necessary for this invariant to be obeyed: indeed the
    stacks that would have otherwise been passed to the continuation
    in the pure semantics were available to the caller in the
    concrete machine. As such, continuations are only required to
    demand the values of X and o, with all other values closed over
    during suspension. -}
data Γ s o xs r a = Γ { xs    :: QList xs
                      , ret   :: Code (r -> Unboxed o -> ST s (Maybe a))
                      , o     :: Code o
                      , hs    :: [Code (Unboxed o -> ST s (Maybe a))] }

newtype IMVar = IMVar Word64 deriving (Ord, Eq, Num, Enum, Show)
newtype IΦVar = IΦVar Word64 deriving (Ord, Eq, Num, Enum, Show)
newtype IΣVar = IΣVar Word64 deriving (Ord, Eq, Num, Enum, Show)
newtype QSTRef s x = QSTRef (Code (STRef s x))
newtype QORef s = QORef (Code (STRefU s Int))
data Ctx s o a = Ctx { μs         :: DMap MVar (QAbsExec s o a)
                     , φs         :: DMap ΦVar (QJoin s o a)
                     , σs         :: DMap ΣVar (QSTRef s)
                     , stcs       :: Map IΣVar (QORef s)
                     , constCount :: Int
                     , debugLevel :: Int }
emptyCtx :: Ctx s o a
emptyCtx = Ctx DMap.empty DMap.empty DMap.empty Map.empty 0 0

insertM :: MVar x -> Code (AbsExec s o a x) -> Ctx s o a -> Ctx s o a
insertM μ q ctx = ctx {μs = DMap.insert μ (QAbsExec q) (μs ctx)}

insertΦ :: ΦVar x -> Code (x -> Unboxed o -> ST s (Maybe a)) -> Ctx s o a -> Ctx s o a
insertΦ φ qjoin ctx = ctx {φs = DMap.insert φ (QJoin qjoin) (φs ctx)}

insertΣ :: ΣVar x -> Code (STRef s x) -> Ctx s o a -> Ctx s o a
insertΣ σ qref ctx = ctx {σs = DMap.insert σ (QSTRef qref) (σs ctx)}

insertSTC :: ΣVar x -> Code (STRefU s Int) -> Ctx s o a -> Ctx s o a
insertSTC (ΣVar v) qref ctx = ctx {stcs = Map.insert v (QORef qref) (stcs ctx)}

addConstCount :: Int -> Ctx s o a -> Ctx s o a
addConstCount x ctx = ctx {constCount = constCount ctx + x}

skipBounds :: Ctx s o a -> Bool
skipBounds ctx = constCount ctx > 0

debugUp :: Ctx s o a -> Ctx s o a
debugUp ctx = ctx {debugLevel = debugLevel ctx + 1}

debugDown :: Ctx s o a -> Ctx s o a
debugDown ctx = ctx {debugLevel = debugLevel ctx - 1}

newtype MissingDependency = MissingDependency IMVar
newtype OutOfScopeRegister = OutOfScopeRegister IΣVar
type ExecMonad s o xs r a = Reader (Ctx s o a) (Γ s o xs r a -> Code (ST s (Maybe a)))
newtype Exec s o xs r a = Exec { unExec :: ExecMonad s o xs r a }
run :: Exec s o xs r a -> Γ s o xs r a -> Ctx s o a -> Code (ST s (Maybe a))
run (Exec m) γ ctx = runReader m ctx γ

type Ops o = (Handlers o, KOps o, ConcreteExec o, JoinBuilder o, FailureOps o, RecBuilder o)
type Handlers o = (HardForkHandler o, SoftForkHandler o, AttemptHandler o, ChainHandler o, LogHandler o)
class FailureOps o => HardForkHandler o where
  hardForkHandler :: (?ops :: InputOps s o) => (Γ s o xs ks a -> Code (ST s (Maybe a))) -> Γ s o xs ks a -> Code (H s o a -> Unboxed o -> Unboxed o -> ST s (Maybe a))
class FailureOps o => SoftForkHandler o where
  softForkHandler :: (?ops :: InputOps s o) => (Γ s o xs ks a -> Code (ST s (Maybe a))) -> Γ s o xs ks a -> Code (H s o a  -> Unboxed o -> Unboxed o -> ST s (Maybe a))
class FailureOps o => AttemptHandler o where
  attemptHandler :: (?ops :: InputOps s o) => Code (H s o a  -> Unboxed o -> Unboxed o -> ST s (Maybe a))
class FailureOps o => ChainHandler o where
  chainHandler :: (?ops :: InputOps s o) => (Γ s o xs ks a -> Code (ST s (Maybe a))) -> Code (STRefU s Int)
               -> Γ s o xs ks a -> Code (H s o a  -> Unboxed o -> Unboxed o -> ST s (Maybe a))
class FailureOps o => LogHandler o where
  logHandler :: (?ops :: InputOps s o) => String -> Ctx s o a -> Γ s o xs ks a -> Code (H s o a  -> Unboxed o -> Unboxed o -> ST s (Maybe a))

exec :: Ops o => Code (PreparedInput (Rep o) s o (Unboxed o)) -> (Machine o a, DMap MVar (LetBinding o a), [IMVar]) -> Code (ST s (Maybe a))
exec input (Machine !m, ms, topo) = trace ("EXECUTING: " ++ show m) [||
  do let !(PreparedInput next more same offset box unbox newCRef readCRef writeCRef shiftLeft shiftRight toInt) = $$input
     $$(let ?ops = InputOps [||more||] [||next||] [||same||] [||box||] [||unbox||] [||newCRef||] [||readCRef||] [||writeCRef||] [||shiftLeft||] [||shiftRight||] [||toInt||] 
        in scopeBindings ms
             nameLet
             (QAbsExec . unsafeTExpCoerce)
             (\(LetBinding k) names -> buildRec (emptyCtx {μs = names}) (readyExec k))
             (\names -> run (readyExec m) (Γ QNil [||noreturn||] [||offset||] []) (emptyCtx {μs = names})))
  ||]

missingDependency :: MVar x -> MissingDependency
missingDependency (MVar v) = MissingDependency v
dependencyOf :: MissingDependency -> MVar x
dependencyOf (MissingDependency v) = MVar v
outOfScopeRegister :: ΣVar x -> OutOfScopeRegister
outOfScopeRegister (ΣVar σ) = OutOfScopeRegister σ

-- BEGIN NEW CODE

nameLet :: LetBinding o a x -> String
nameLet _ = "rec"

scopeBindings :: forall s o a b key named. GCompare key => DMap key named
                                          -> (forall a. named a -> String)
                                          -> (forall x. Q Exp -> QAbsExec s o a x)
                                          -> (forall x. named x -> DMap key (QAbsExec s o a) -> Code ((x -> Unboxed o -> ST s (Maybe a))
                                                                         -> Unboxed o -> (Unboxed o -> ST s (Maybe a)) -> ST s (Maybe a)))
                                          -> (DMap key (QAbsExec s o a) -> Code b)
                                          -> Code b
scopeBindings bindings nameOf wrap letBuilder scoped = unsafeTExpCoerce $
  do names <- makeNames bindings
     LetE <$> generateBindings names bindings <*> unTypeQ (scoped (package names))
  where
    package = DMap.map (wrap . return . VarE . getConst)

    makeNames :: DMap key named -> Q (DMap key (Const Name))
    makeNames = DMap.traverseWithKey (\_ v -> Const <$> newName (nameOf v))

    generateBindings :: DMap key (Const Name) -> DMap key named -> Q [Dec]
    generateBindings names = traverse makeDecl . DMap.toList
      where
        makeDecl :: DSum key named -> Q Dec
        makeDecl (k :=> v) = 
          do let Const name = names DMap.! k
             body <- unTypeQ (letBuilder v (package names))
             return (FunD name [Clause [] (NormalB body) []])

-- END NEW CODE

readyExec :: (?ops :: InputOps s o, Ops o) => Free3 (M o) Void3 xs r a -> Exec s o xs r a
readyExec = fold3 absurd (Exec . alg)
  where
    alg :: (?ops :: InputOps s o, Ops o) => M o (Exec s o) xs r a -> ExecMonad s o xs r a
    alg Halt                   = execHalt
    alg Ret                    = execRet
    alg (Call μ k)             = execCall μ k
    alg (Jump μ)               = execJump μ
    alg (Push x k)             = execPush x k
    alg (Pop k)                = execPop k
    alg (Lift2 f k)            = execLift2 f k
    alg (Sat p k)              = execSat p k
    alg Empt                   = execEmpt
    alg (Commit exit k)        = execCommit exit k
    alg (HardFork p q φ)       = execHardFork p q φ
    alg (SoftFork n p q φ)     = execSoftFork n p q φ
    alg (Join φ)               = execJoin φ
    alg (Attempt n k)          = execAttempt n k
    alg (Tell k)               = execTell k
    alg (Seek k)               = execSeek k
    alg (Case p q  φ)          = execCase p q  φ
    alg (Choices fs ks def  φ) = execChoices fs ks def  φ
    alg (ChainIter σ μ)        = execChainIter σ μ
    alg (ChainInit σ l μ k)    = execChainInit σ l μ k
    alg (Swap k)               = execSwap k
    alg (Make σ k)             = execMake σ k
    alg (Get σ k)              = execGet σ k
    alg (Put σ k)              = execPut σ k
    alg (LogEnter name k)      = execLogEnter name k
    alg (LogExit name k)       = execLogExit name k

execHalt :: ExecMonad s o '[a] r a
execHalt = return $! \γ -> [|| return $! Just $! $$(headQ (xs γ)) ||]

execRet :: (?ops :: InputOps s o, KOps o) => ExecMonad s o (x ': xs) x a
execRet = return $! resume

execCall :: (?ops :: InputOps s o, ConcreteExec o, KOps o) => MVar x -> Exec s o (x ': xs) r a -> ExecMonad s o xs r a
execCall μ (Exec k) =
  do !(QAbsExec m) <- askM μ
     mk <- k
     return $ \γ@Γ{..} -> [|| $$(runConcrete hs) $$m $$(suspend mk γ) $$o ||]

execJump :: (?ops :: InputOps s o, ConcreteExec o) => MVar x -> ExecMonad s o '[] x a
execJump μ =
  do !(QAbsExec m) <- askM μ
     return $! \γ@Γ{..} -> [|| $$(runConcrete hs) $$m $$ret $$o ||]

execPush :: WQ x -> Exec s o (x ': xs) r a -> ExecMonad s o xs r a
execPush x (Exec k) = fmap (\m γ -> m (γ {xs = QCons (_code x) (xs γ)})) k

execPop :: Exec s o xs r a -> ExecMonad s o (x ': xs) r a
execPop (Exec k) = fmap (\m γ -> m (γ {xs = tailQ (xs γ)})) k

execLift2 :: WQ (x -> y -> z) -> Exec s o (z ': xs) r a -> ExecMonad s o (y ': x ': xs) r a
execLift2 f (Exec k) = fmap (\m γ -> m (γ {xs = let QCons y (QCons x xs') = xs γ in QCons [||$$(_code f) $$x $$y||] xs'})) k

execSat :: (?ops :: InputOps s o, FailureOps o) => WQ (Char -> Bool) -> Exec s o (Char ': xs) r a -> ExecMonad s o xs r a
execSat p (Exec k) =
  do mk <- k
     asks $! \ctx γ -> nextSafe (skipBounds ctx) (o γ) (_code p) (\o c -> mk (γ {xs = QCons c (xs γ), o = o})) (raiseΓ γ)

execEmpt :: (?ops :: InputOps s o, FailureOps o) => ExecMonad s o xs r a
execEmpt = return $! raiseΓ

execCommit :: Bool -> Exec s o xs r a -> ExecMonad s o xs r a
execCommit exit (Exec k) = local (\ctx -> if exit then addConstCount (-1) ctx else ctx)
                                 (fmap (\m γ -> m (γ {hs = tail (hs γ)})) k)

execHardFork :: (?ops :: InputOps s o, HardForkHandler o, JoinBuilder o) => Exec s o xs r a -> Exec s o xs r a -> Maybe (ΦDecl (Exec s o) x xs r a) -> ExecMonad s o xs r a
execHardFork (Exec p) (Exec q) decl = setupJoinPoint decl id $
  do mp <- p
     mq <- q
     return $! \γ -> setupHandlerΓ γ (hardForkHandler mq γ) mp

#define deriveHardForkHandler(_o)                                  \
instance HardForkHandler _o where                                  \
{                                                                  \
  hardForkHandler mq γ = [||\h (!o#) (!c#) ->                      \
      if $$same ($$box c#) ($$box o#) then                         \
        $$(mq (γ {o = [||$$box o#||], hs = [||h||] : (hs γ)})) \
      else h o#                                                    \
    ||]                                                            \
};
inputInstances(deriveHardForkHandler)

execSoftFork :: (?ops :: InputOps s o, SoftForkHandler o, JoinBuilder o) => Maybe Int -> Exec s o xs r a -> Exec s o xs r a -> Maybe (ΦDecl (Exec s o) x xs r a) -> ExecMonad s o xs r a
execSoftFork constantInput (Exec p) (Exec q) decl = setupJoinPoint decl id $
  do mp <- inputSizeCheck constantInput p
     mq <- q
     return $! \γ -> setupHandlerΓ γ (softForkHandler mq γ) mp

#define deriveSoftForkHandler(_o) \
instance SoftForkHandler _o where { softForkHandler mq γ = [||\h _ (!c#) -> $$(mq (γ {o = [||$$box c#||], hs = [||h||] : (hs γ)}))||] };
inputInstances(deriveSoftForkHandler)

execJoin :: (?ops :: InputOps s o) => ΦVar x -> ExecMonad s o (x ': xs) r a
execJoin φ =
  do QJoin k <- asks ((DMap.! φ) . φs)
     return $! \γ -> [|| $$k $$(headQ (xs γ)) ($$unbox $$(o γ)) ||]

execAttempt :: (?ops :: InputOps s o, AttemptHandler o) => Maybe Int -> Exec s o xs r a -> ExecMonad s o xs r a
execAttempt constantInput (Exec k) = do mk <- inputSizeCheck constantInput k; return $! \γ -> setupHandlerΓ γ attemptHandler mk

#define deriveAttemptHandler(_o) \
instance AttemptHandler _o where { attemptHandler = [||\h _ (!c#) -> h c#||] };
inputInstances(deriveAttemptHandler)

execTell :: Exec s o (o ': xs) r a -> ExecMonad s o xs r a
execTell (Exec k) = fmap (\mk γ -> mk (γ {xs = QCons (o γ) (xs γ)})) k

execSeek :: Exec s o xs r a -> ExecMonad s o (o ': xs) r a
execSeek (Exec k) = fmap (\mk γ -> let QCons o xs' = xs γ in mk (γ {xs = xs', o=o})) k

execCase :: (?ops :: InputOps s o, JoinBuilder o) => Exec s o (x ': xs) r a -> Exec s o (y ': xs) r a -> Maybe (ΦDecl (Exec s o) z xs r a) -> ExecMonad s o (Either x y ': xs) r a
execCase (Exec p) (Exec q) decl = setupJoinPoint decl tailQ $
  do mp <- p
     mq <- q
     return $! \γ ->
         let QCons e xs' = xs γ
         in [||case $$e of
           Left x -> $$(mp (γ {xs = QCons [||x||] xs'}))
           Right y  -> $$(mq (γ {xs = QCons [||y||] xs'}))||]

execChoices :: forall x y xs r a s o. (?ops :: InputOps s o, JoinBuilder o) => [WQ (x -> Bool)] -> [Exec s o xs r a] -> Exec s o xs r a -> Maybe (ΦDecl (Exec s o) y xs r a) -> ExecMonad s o (x ': xs) r a
execChoices fs ks (Exec def) decl = setupJoinPoint decl tailQ $
  do mdef <- def
     fmap (\mks γ -> let QCons x xs' = xs γ in go x fs mks mdef (γ {xs = xs'})) (forM ks (\(Exec k) -> k))
  where
    go :: Code x -> [WQ (x -> Bool)] -> [Γ s o xs r a -> Code (ST s (Maybe a))] -> (Γ s o xs r a -> Code (ST s (Maybe a))) -> Γ s o xs r a -> Code (ST s (Maybe a))
    go _ [] [] def γ = def γ
    go x (f:fs) (mk:mks) def γ = [||
        if $$(_code f) $$x then $$(mk γ)
        else $$(go x fs mks def γ)
      ||]

execChainIter :: (?ops :: InputOps s o, ConcreteExec o) => ΣVar x -> MVar x -> ExecMonad s o '[] x a
execChainIter σ μ =
  do !(QAbsExec l) <- askM μ
     !(QORef cref) <- askSTC σ
     return $! \γ@Γ{..} -> [||
       do $$writeCRef $$cref $$o
          $$(runConcrete hs) $$l $$ret $$o
       ||]

execChainInit :: (?ops :: InputOps s o, ChainHandler o, RecBuilder o) => ΣVar x -> Exec s o '[] x a -> MVar x -> Exec s o xs r a
              -> ExecMonad s o xs r a
execChainInit σ l μ (Exec k) =
  do mk <- k
     asks $! \ctx γ@(Γ xs ks o _) -> [||
        do cref <- $$newCRef $$o
           $$(setupHandlerΓ γ (chainHandler mk [||cref||] γ) (\γ' ->
              buildIter ctx μ σ l [||cref||] (hs γ') o))
      ||]

#define deriveChainHandler(_o)                   \
instance ChainHandler _o where                   \
{                                                \
  chainHandler mk cref γ = [||\h (!o#) _ ->      \
      do                                         \
      {                                          \
        c <- $$readCRef $$cref;                  \
        if $$same c ($$box o#) then              \
          $$(mk (γ {o = [|| $$box o# ||],        \
                    hs = [||h||] : hs γ}))       \
        else h o#                                \
      } ||]                                      \
};
inputInstances(deriveChainHandler)

execSwap :: Exec s o (x ': y ': xs) r a -> ExecMonad s o (y ': x ': xs) r a
execSwap (Exec k) = fmap (\mk γ -> mk (γ {xs = let QCons y (QCons x xs') = xs γ in QCons x (QCons y xs')})) k

execMake :: ΣVar x -> Exec s o xs r a -> ExecMonad s o (x ': xs) r a
execMake σ k = asks $! \ctx γ -> let QCons x xs' = xs γ in [||
                  do ref <- newΣ $$x
                     $$(run k (γ {xs = xs'}) (insertΣ σ [||ref||] ctx))
                ||]

execGet :: ΣVar x -> Exec s o (x ': xs) r a -> ExecMonad s o xs r a
execGet σ (Exec k) =
  do !(QSTRef ref) <- askΣ σ
     mk <- k
     return $! \γ -> [||
       do x <- readΣ $$ref
          $$(mk (γ {xs = QCons [||x||] (xs γ)}))
       ||]

execPut :: ΣVar x -> Exec s o xs r a -> ExecMonad s o (x ': xs) r a
execPut σ (Exec k) =
  do !(QSTRef ref) <- askΣ σ
     mk <- k
     return $! \γ -> let QCons x xs' = xs γ in [||
       do writeΣ $$ref $$x
          $$(mk (γ {xs = xs'}))
       ||]

preludeString :: (?ops :: InputOps s o) => String -> Char -> Γ s o xs r a -> Ctx s o a -> String -> Code String
preludeString name dir γ ctx ends = [|| concat [$$prelude, $$eof, ends, '\n' : $$caretSpace, color Blue "^"] ||]
  where
    offset     = o γ
    indent     = replicate (debugLevel ctx * 2) ' '
    start      = [|| $$shiftLeft $$offset 5 ||]
    end        = [|| $$shiftRight $$offset 5 ||]
    inputTrace = [|| let replace '\n' = color Green "↙"
                         replace ' '  = color White "·"
                         replace c    = return c
                         go i
                           | $$same i $$end = []
                           | otherwise  = let (# c, i' #) = $$next i in replace c ++ go i'
                     in go $$start ||]
    eof        = [|| if $$more $$end then $$inputTrace else $$inputTrace ++ color Red "•" ||]
    prelude    = [|| concat [indent, dir : name, dir : " (", show ($$offToInt $$offset), "): "] ||]
    caretSpace = [|| replicate (length $$prelude + $$offToInt $$offset - $$offToInt $$start) ' ' ||]

execLogEnter :: (?ops :: InputOps s o, LogHandler o) => String -> Exec s o xs r a -> ExecMonad s o xs r a
execLogEnter name (Exec mk) =
  do k <- local debugUp mk
     asks $! \ctx γ ->
      (setupHandlerΓ γ (logHandler name ctx γ) (\γ' -> [|| trace $$(preludeString name '>' γ ctx "") $$(k γ')||]))

#define deriveLogHandler(_o)                                                                   \
instance LogHandler _o where                                                                   \
{                                                                                              \
  logHandler name ctx γ = [||\h o# _ ->                                                        \
      trace $$(preludeString name '<' (γ {o = [||$$box o#||]}) ctx (color Red " Fail")) (h o#) \
    ||]                                                                                        \
};
inputInstances(deriveLogHandler)

execLogExit :: (?ops :: InputOps s o) => String -> Exec s o xs r a -> ExecMonad s o xs r a
execLogExit name (Exec mk) =
  do k <- local debugDown mk
     asks $! \ctx γ -> [|| trace $$(preludeString name '<' γ (debugDown ctx) (color Green " Good")) $$(k γ) ||]

setupHandlerΓ :: (?ops :: InputOps s o, FailureOps o) => Γ s o xs r a -> Code (H s o a  -> Unboxed o -> Unboxed o -> ST s (Maybe a)) ->
                                                                               (Γ s o xs r a -> Code (ST s (Maybe a))) -> Code (ST s (Maybe a))
setupHandlerΓ γ !h !k = setupHandler (hs γ) (o γ) h (\hs -> k (γ {hs = hs}))

class RecBuilder o => JoinBuilder o where
  setupJoinPoint :: (?ops :: InputOps s o) => Maybe (ΦDecl (Exec s o) y ys r a)
                 -> (QList xs -> QList ys)
                 -> ExecMonad s o xs r a
                 -> ExecMonad s o xs r a

#define deriveJoinBuilder(_o)                                                               \
instance JoinBuilder _o where                                                               \
{                                                                                           \
  setupJoinPoint Nothing adapt mx = mx;                                                     \
  setupJoinPoint (Just (φ, (Exec k))) adapt mx =                                            \
    do                                                                                      \
    {                                                                                       \
      ctx <- ask;                                                                           \
      fmap (\mk γ -> [||                                                                    \
        let join x !o# = $$(mk (γ {xs = QCons [||x||] (adapt (xs γ)), o = [||$$box o#||]})) \
        in $$(run (Exec mx) γ (insertΦ φ [||join||] ctx))                                   \
      ||]) k                                                                                \
    }                                                                                       \
};
inputInstances(deriveJoinBuilder)

class RecBuilder o where
  buildIter :: (?ops :: InputOps s o) => Ctx s o a -> MVar x -> ΣVar x -> Exec s o '[] x a
            -> Code (STRefU s Int)
            -> [Code (H s o a)] -> Code o -> Code (ST s (Maybe a))
  buildRec  :: (?ops :: InputOps s o) => Ctx s o a
            -> Exec s o '[] r a
            -> Code ((r -> Unboxed o -> ST s (Maybe a)) -> Unboxed o 
                                                        -> (Unboxed o -> ST s (Maybe a)) 
                                                        -> ST s (Maybe a))

#define deriveRecBuilder(_o)                                                          \
instance RecBuilder _o where                                                          \
{                                                                                     \
  buildIter ctx μ σ l cref hs o = let bx = box in [||                                 \
      do                                                                              \
      {                                                                               \
        let {loop !o# =                                                               \
          $$(let ctx' = insertSTC σ cref (insertM μ [||\_ (!o#) _ -> loop o#||] ctx); \
                 γ = Γ QNil [||noreturn||] [||$$bx o#||] hs                           \
             in run l γ ctx')};                                                       \
        loop ($$unbox $$o)                                                            \
      } ||];                                                                          \
  buildRec ctx k = let bx = box in [|| \(!ret) (!o#) h ->                             \
    $$(run k (Γ QNil [||ret||] [||$$bx o#||] [[||h||]]) ctx) ||]                      \
};
inputInstances(deriveRecBuilder)

inputSizeCheck :: (?ops :: InputOps s o, FailureOps o) => Maybe Int -> ExecMonad s o xs r a -> ExecMonad s o xs r a
inputSizeCheck Nothing p = p
inputSizeCheck (Just n) p =
  do skip <- asks skipBounds
     mp <- local (addConstCount 1) p
     if skip then return $! mp
     else if n == 1 then fmap (\ctx γ -> [|| if $$more $$(o γ) then $$(mp γ) else $$(raiseΓ γ) ||]) ask
     else fmap (\ctx γ -> [||
        if $$more ($$shiftRight $$(o γ) (n - 1)) then $$(mp γ)
        else $$(raiseΓ γ)
      ||]) ask

raiseΓ :: (?ops :: InputOps s o, FailureOps o) => Γ s o xs r a -> Code (ST s (Maybe a))
raiseΓ γ = [|| $$(raise(hs γ)) $$(o γ) ||]

class KOps o where
  suspend :: (?ops :: InputOps s o) => (Γ s o (x ': xs) r a -> Code (ST s (Maybe a))) -> Γ s o xs r a -> Code (x -> Unboxed o -> ST s (Maybe a))
  resume :: (?ops :: InputOps s o) => Γ s o (x ': xs) x a -> Code (ST s (Maybe a))

#define deriveKOps(_o)                                                                         \
instance KOps _o where                                                                         \
{                                                                                              \
  suspend m γ = [|| \x (!o#) -> $$(m (γ {xs = QCons [||x||] (xs γ), o = [||$$box o#||]})) ||]; \
  resume γ = [|| $$(ret γ) $$(headQ (xs γ)) ($$unbox $$(o γ)) ||]                                \
};
inputInstances(deriveKOps)

askM :: MonadReader (Ctx s o a) m => MVar x -> m (QAbsExec s o a x)
askM μ = trace ("fetching " ++ show μ) $ do
  mexec <- asks (((DMap.lookup μ) . μs))
  case mexec of
    Just exec -> return $! exec
    Nothing   -> throw (missingDependency μ)

askΣ :: MonadReader (Ctx s o a) m => ΣVar x -> m (QSTRef s x)
askΣ σ = trace ("fetching " ++ show σ) $ do
  mref <- asks ((DMap.lookup σ) . σs)
  case mref of
    Just ref -> return $! ref
    Nothing  -> throw (outOfScopeRegister σ)

askΦ :: MonadReader (Ctx s o a) m => ΦVar x -> m (QJoin s o a x)
askΦ φ = trace ("fetching " ++ show φ) $ asks ((DMap.! φ) . φs)

askSTC :: MonadReader (Ctx s o a) m => ΣVar x -> m (QORef s)
askSTC (ΣVar v) = asks ((Map.! v) . stcs)

instance IFunctor3 (M o) where
  imap3 f Halt                              = Halt
  imap3 f Ret                               = Ret
  imap3 f (Push x k)                        = Push x (f k)
  imap3 f (Pop k)                           = Pop (f k)
  imap3 f (Lift2 g k)                       = Lift2 g (f k)
  imap3 f (Sat g k)                         = Sat g (f k)
  imap3 f (Call μ k)                        = Call μ (f k)
  imap3 f (Jump μ)                          = Jump μ
  imap3 f Empt                              = Empt
  imap3 f (Commit exit k)                   = Commit exit (f k)
  imap3 f (SoftFork n p q (Just (φ, k)))    = SoftFork n (f p) (f q) (Just (φ, f k))
  imap3 f (SoftFork n p q Nothing)          = SoftFork n (f p) (f q) Nothing
  imap3 f (HardFork p q (Just (φ, k)))      = HardFork (f p) (f q) (Just (φ, f k))
  imap3 f (HardFork p q Nothing)            = HardFork (f p) (f q) Nothing
  imap3 f (Join φ)                          = Join φ
  imap3 f (Attempt n k)                     = Attempt n (f k)
  imap3 f (Tell k)                          = Tell (f k)
  imap3 f (Seek k)                          = Seek (f k)
  imap3 f (Case p q (Just (φ, k)))          = Case (f p) (f q) (Just (φ, f k))
  imap3 f (Case p q Nothing)                = Case (f p) (f q) Nothing
  imap3 f (Choices fs ks def (Just (φ, k))) = Choices fs (map f ks) (f def) (Just (φ, f k))
  imap3 f (Choices fs ks def Nothing)       = Choices fs (map f ks) (f def) Nothing
  imap3 f (ChainIter σ μ)                   = ChainIter σ μ
  imap3 f (ChainInit σ l μ k)               = ChainInit σ (f l) μ (f k)
  imap3 f (Swap k)                          = Swap (f k)
  imap3 f (Make σ k)                        = Make σ (f k)
  imap3 f (Get σ k)                         = Get σ (f k)
  imap3 f (Put σ k)                         = Put σ (f k)
  imap3 f (LogEnter name k)                 = LogEnter name (f k)
  imap3 f (LogExit name k)                  = LogExit name (f k)

instance Show (Machine o a) where show = show . getMachine
instance Show (Free3 (M o) f xs ks a) where
  show = getConst3 . fold3 (const (Const3 "")) (Const3 . alg) where
    alg :: forall i j k. M o (Const3 String) i j k -> String
    alg Halt                                  = "Halt"
    alg Ret                                   = "Ret"
    alg (Call μ k)                            = "(Call " ++ show μ ++ " " ++ getConst3 k ++ ")"
    alg (Jump μ)                              = "(Jump " ++ show μ ++ ")"
    alg (Push _ k)                            = "(Push x " ++ getConst3 k ++ ")"
    alg (Pop k)                               = "(Pop " ++ getConst3 k ++ ")"
    alg (Lift2 _ k)                           = "(Lift2 f " ++ getConst3 k ++ ")"
    alg (Sat _ k)                             = "(Sat f " ++ getConst3 k ++ ")"
    alg Empt                                  = "Empt"
    alg (Commit True k)                       = "(Commit end " ++ getConst3 k ++ ")"
    alg (Commit False k)                      = "(Commit " ++ getConst3 k ++ ")"
    alg (SoftFork Nothing p q Nothing)        = "(SoftFork " ++ getConst3 p ++ " " ++ getConst3 q ++ ")"
    alg (SoftFork (Just n) p q Nothing)       = "(SoftFork " ++ show n ++ " " ++ getConst3 p ++ " " ++ getConst3 q ++ ")"
    alg (SoftFork Nothing p q (Just (φ, k)))  = "(SoftFork " ++ getConst3 p ++ " " ++ getConst3 q ++ " (" ++ show φ ++ " = " ++ getConst3 k ++ "))"
    alg (SoftFork (Just n) p q (Just (φ, k))) = "(SoftFork " ++ show n ++ " " ++ getConst3 p ++ " " ++ getConst3 q ++ " (" ++ show φ ++ " = " ++ getConst3 k ++ "))"
    alg (HardFork p q Nothing)                = "(HardFork " ++ getConst3 p ++ " " ++ getConst3 q ++ ")"
    alg (HardFork p q (Just (φ, k)))          = "(HardFork " ++ getConst3 p ++ " " ++ getConst3 q ++ " (" ++ show φ ++ " = " ++ getConst3 k ++ "))"
    alg (Join φ)                              = show φ
    alg (Attempt Nothing k)                   = "(Try " ++ getConst3 k ++ ")"
    alg (Attempt (Just n) k)                  = "(Try " ++ show n ++ " " ++ getConst3 k ++ ")"
    alg (Tell k)                              = "(Tell " ++ getConst3 k ++ ")"
    alg (Seek k)                              = "(Seek " ++ getConst3 k ++ ")"
    alg (Case p q Nothing)                    = "(Case " ++ getConst3 p ++ " " ++ getConst3 q ++ ")"
    alg (Case p q (Just (φ, k)))              = "(Case " ++ getConst3 p ++ " " ++ getConst3 q ++ " (" ++ show φ ++ " = " ++ getConst3 k ++ "))"
    alg (Choices _ ks def Nothing)            = "(Choices [" ++ intercalate ", " (map getConst3 ks) ++ "] " ++ getConst3 def ++ ")"
    alg (Choices _ ks def (Just (φ, k)))      = "(Choices [" ++ intercalate ", " (map getConst3 ks) ++ "] " ++ getConst3 def ++ " (" ++ show φ ++ " = " ++ getConst3 k ++ "))"
    alg (ChainIter σ μ)                       = "(ChainIter " ++ show σ ++ " " ++ show μ ++ ")"
    alg (ChainInit σ m μ k)                   = "{ChainInit " ++ show σ ++ " " ++ show μ ++ " " ++ getConst3 m ++ " " ++ getConst3 k ++ "}"
    alg (Swap k)                              = "(Swap " ++ getConst3 k ++ ")"
    alg (Make σ k)                            = "(Make " ++ show σ ++ " " ++ getConst3 k ++ ")"
    alg (Get σ k)                             = "(Get " ++ show σ ++ " " ++ getConst3 k ++ ")"
    alg (Put σ k)                             = "(Put " ++ show σ ++ " " ++ getConst3 k ++ ")"
    alg (LogEnter _ k)                        = getConst3 k
    alg (LogExit _ k)                         = getConst3 k

instance Show (MVar a) where show (MVar (IMVar μ)) = "μ" ++ show μ
instance Show (ΦVar a) where show (ΦVar (IΦVar φ)) = "φ" ++ show φ
instance Show (ΣVar a) where show (ΣVar (IΣVar σ)) = "σ" ++ show σ

instance Show MissingDependency where show (MissingDependency (IMVar μ)) = "Dependency μ" ++ show μ ++ " has not been compiled"
instance Exception MissingDependency

instance Show OutOfScopeRegister where show (OutOfScopeRegister (IΣVar σ)) = "Register r" ++ show σ ++ " is out of scope"
instance Exception OutOfScopeRegister

instance GEq ΣVar where
  geq (ΣVar u) (ΣVar v)
    | u == v    = Just (coerce Refl)
    | otherwise = Nothing

instance GCompare ΣVar where
  gcompare (ΣVar u) (ΣVar v) = case compare u v of
    LT -> coerce GLT
    EQ -> coerce GEQ
    GT -> coerce GGT

instance GEq ΦVar where
  geq (ΦVar u) (ΦVar v)
    | u == v    = Just (coerce Refl)
    | otherwise = Nothing

instance GCompare ΦVar where
  gcompare (ΦVar u) (ΦVar v) = case compare u v of
    LT -> coerce GLT
    EQ -> coerce GEQ
    GT -> coerce GGT

instance GEq MVar where
  geq (MVar u) (MVar v)
    | u == v    = Just (coerce Refl)
    | otherwise = Nothing

instance GCompare MVar where
  gcompare (MVar u) (MVar v) = case compare u v of
    LT -> coerce GLT
    EQ -> coerce GEQ
    GT -> coerce GGT