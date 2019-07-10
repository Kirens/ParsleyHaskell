{-# LANGUAGE GADTs,
             DataKinds,
             KindSignatures,
             PolyKinds,
             TypeOperators,
             BangPatterns,
             MagicHash,
             UnboxedTuples,
             TemplateHaskell,
             TypeSynonymInstances,
             RankNTypes,
             CPP,
             ImplicitParams #-}
module MachineOps where

import Utils              (TExpQ)
import Control.Monad.ST   (ST)
import Data.STRef         (STRef, writeSTRef, readSTRef, newSTRef)
import GHC.Prim           (Int#)
import GHC.Exts           (Int(..), TYPE, RuntimeRep(..))
import Safe.Coerce        (coerce)
import Input              (Rep, CRef, Unboxed, OffWith, UnpackedLazyByteString)
import Data.Text          (Text)
import Data.Void          (Void)

#define inputInstances(derivation) \
derivation(O)                      \
derivation((OffWith s))            \
derivation(UnpackedLazyByteString) \
derivation(Text)

data QList as where
  QNil :: QList '[]
  QCons :: !(TExpQ a) -> QList as -> QList (a ': as)

type H s o a = H_ (Rep o) s (Unboxed o) a
type H_ r s (o# :: TYPE r) a = o# -> ST s (Maybe a)
type X = QList
type O = Int
type O# = Int#
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
type K s o x a = K_ (Rep o) s (Unboxed o) x a
type K_ r s (o# :: TYPE r) x a = x -> o# -> ST s (Maybe a)
data InputOps s o = InputOps { _more       :: TExpQ (o -> Bool)
                             , _next       :: TExpQ (o -> (# Char, o #))
                             , _same       :: TExpQ (o -> o -> Bool)
                             , _box        :: TExpQ (Unboxed o -> o)
                             , _unbox      :: TExpQ (o -> Unboxed o)
                             , _newCRef    :: TExpQ (o -> ST s (CRef s o))
                             , _readCRef   :: TExpQ (CRef s o -> ST s o)
                             , _writeCRef  :: TExpQ (CRef s o -> o -> ST s ())
                             , _shiftLeft  :: TExpQ (o -> Int -> o)
                             , _shiftRight :: TExpQ (o -> Int -> o)
                             , _offToInt   :: TExpQ (o -> Int) }

more       :: (?ops :: InputOps s o) => TExpQ (o -> Bool)
more       = _more       ?ops
next       :: (?ops :: InputOps s o) => TExpQ (o -> (# Char, o #))
next       = _next       ?ops
same       :: (?ops :: InputOps s o) => TExpQ (o -> o -> Bool)
same       = _same       ?ops
unbox      :: (?ops :: InputOps s o) => TExpQ (o -> Unboxed o)
unbox      = _unbox      ?ops
box        :: (?ops :: InputOps s o) => TExpQ (Unboxed o -> o)
box        = _box        ?ops
newCRef    :: (?ops :: InputOps s o) => TExpQ (o -> ST s (CRef s o))
newCRef    = _newCRef    ?ops
readCRef   :: (?ops :: InputOps s o) => TExpQ (CRef s o -> ST s o) 
readCRef   = _readCRef   ?ops
writeCRef  :: (?ops :: InputOps s o) => TExpQ (CRef s o -> o -> ST s ())
writeCRef  = _writeCRef  ?ops
shiftLeft  :: (?ops :: InputOps s o) => TExpQ (o -> Int -> o)
shiftLeft  = _shiftLeft  ?ops
shiftRight :: (?ops :: InputOps s o) => TExpQ (o -> Int -> o)
shiftRight = _shiftRight ?ops
offToInt   :: (?ops :: InputOps s o) => TExpQ (o -> Int)
offToInt   = _offToInt   ?ops

type AbsExec r s (o# :: TYPE r) a x = K_ r s o# x a -> o# -> H_ r s o# a -> ST s (Maybe a)
newtype QAbsExec s o a x = QAbsExec (TExpQ (AbsExec (Rep o) s (Unboxed o) a x))
newtype QJoin r s (o# :: TYPE r) a x = QJoin (TExpQ (x -> o# -> ST s (Maybe a)))

type QH s o a = TExpQ (H s o a)
type QK s o x a = TExpQ (K s o x a)
type QO o = TExpQ o
type QST s a = TExpQ (ST s a)

makeX :: X '[]
makeX = QNil
{-# INLINE pushX #-}
pushX :: TExpQ a -> X xs -> X (a ': xs)
pushX x xs = QCons x xs
{-# INLINE popX #-}
popX :: X (a ': xs) -> (# TExpQ a, X xs #)
popX (QCons x xs) = (# x, xs #)
{-# INLINE popX_ #-}
popX_ :: X (a ': xs) -> X xs
popX_ (QCons x xs) = xs
{-# INLINE pokeX #-}
pokeX :: TExpQ a -> X (b ': xs) -> X (a ': xs)
pokeX y (QCons x xs) = QCons y xs
{-# INLINE peekX #-}
peekX :: X (a ': xs) -> TExpQ a
peekX (QCons x xs) = x

makeK :: ST s (K_ k s o Void a)
makeK = return $! noreturn
noreturn :: K_ k s o x a
noreturn x = error "Machine is only permitted return-by-failure"

makeH :: [TExpQ (H_ r s o# a)]
makeH = []
pushH :: TExpQ (H_ r s o# a) -> [TExpQ (H_ r s o# a)] -> [TExpQ (H_ r s o# a)]
pushH h hs = (h:hs)
{-# INLINE popH_ #-}
popH_ :: [TExpQ (H_ r s o# a)] -> [TExpQ (H_ r s o# a)]
popH_ (_:hs) = hs

{-# INLINE newΣ #-}
newΣ :: x -> ST s (STRef s x)
newΣ x = newSTRef x
{-# INLINE writeΣ #-}
writeΣ :: STRef s x -> x -> ST s ()
writeΣ ref x = writeSTRef ref x
{-# INLINE readΣ #-}
readΣ :: STRef s x -> ST s x
readΣ ref = readSTRef ref
{-# INLINE modifyΣ #-}
modifyΣ :: STRef s x -> (x -> x) -> ST s ()
modifyΣ σ f =
  do !x <- readΣ σ
     writeΣ σ (f $! x)

class FailureOps o where
  setupHandler :: (?ops :: InputOps s o) => [QH s o a] -> QO o
               -> TExpQ (H s o a -> Unboxed o -> Unboxed o -> ST s (Maybe a)) 
               -> ([QH s o a] -> QST s (Maybe a)) -> QST s (Maybe a)
  raise :: (?ops :: InputOps s o) => [QH s o a] -> TExpQ (o -> ST s (Maybe a))

#define deriveFailureOps(_o)                                   \
instance FailureOps _o where                                   \
{                                                              \
  setupHandler hs !o !h !k =                                   \
    let h' = case hs of                                        \
    {                                                          \
      h':_ -> h';                                              \
      [] -> [||\o# -> return Nothing :: ST s (Maybe a)||]      \
    }                                                          \
    in k (pushH [||\(!o#) -> $$h $$h' o# ($$unbox $$o)||] hs); \
  raise [] = [||\(!o) -> return Nothing||];                    \
  raise (h:_) = [||\(!o) -> $$h ($$unbox o)||];                \
};
inputInstances(deriveFailureOps)

-- RIP Dream :(
{-$(let derive _o = [d| 
        instance FailureOps _o where
          setupHandler ops hs !o !h !k = k [|| pushH (\(!o#) -> $$h $$hs o# ($$(_unbox ops) $$o)) $$hs ||]
          raise ops = [||\(H hs) (!o) -> case hs of 
              SNil -> return Nothing
              h:::_ -> h ($$(_unbox ops) o)
            ||]
        |] in traverse derive inputTypes)-}

class ConcreteExec o where
  runConcrete :: (?ops :: InputOps s o) => [TExpQ (H s o a)] -> TExpQ (AbsExec (Rep o) s (Unboxed o) a x -> K s o x a -> o -> ST s (Maybe a))

#define deriveConcreteExec(_o)                                                    \
instance ConcreteExec _o where                                                    \
{                                                                                 \
  runConcrete []    = [||\m ks o -> m ks ($$unbox o) $! \o# -> return Nothing||]; \
  runConcrete (h:_) = [||\m ks o -> m ks ($$unbox o) $! $$h||]                    \
};
inputInstances(deriveConcreteExec)

nextSafe :: (?ops :: InputOps s o) => Bool -> QO o -> TExpQ (Char -> Bool) -> (QO o -> TExpQ Char -> QST s (Maybe a)) -> QST s (Maybe a) -> QST s (Maybe a)
nextSafe True o p good bad = [|| let !(# c, o' #) = $$next $$o in if $$p c then $$(good [|| o' ||] [|| c ||]) else $$bad ||]
nextSafe False o p good bad = [||
    let bad' = $$bad in
      if  $$more $$o then let !(# c, o' #) = $$next $$o in if $$p c then $$(good [|| o' ||] [|| c ||]) else bad'
      else bad'
  ||]