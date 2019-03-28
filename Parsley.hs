{-# LANGUAGE GADTs #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE RecursiveDo #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE UndecidableInstances #-}
{-# LANGUAGE MagicHash, UnboxedTuples #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE PolyKinds #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE DeriveFunctor, DeriveLift #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE LambdaCase, MultiWayIf #-}
module Parsley {-( Parser--, CompiledParser
               , runParser--, mkParser, runCompiledParser
               -- Functor
               , fmap, (<$>), (<$), ($>), (<&>), void
               -- Applicative
               , pure, (<*>), (*>), (<*), (<**>), (<:>), liftA2
               -- Alternative
               , empty, (<|>), some, many, optional, choice
               -- Monoidal
               , {-Monoidal,-} unit, (<~>), (<~), (~>)
               -- Monadic
               , return, (>>=), (>>), mzero, mplus, join
               -- Primitives
               , satisfy, item
               , lookAhead, {-notFollowedBy,-} try
               -- Composites
               , char, {-eof,-} more
               --, traverse, sequence, string--, manyUnrolled
               , eval, runST, compile, preprocess
               )-} where

import Prelude hiding          (fmap, pure, (<*), (*>), (<*>), (<$>), (<$))
--import Control.Applicative     (Alternative, (<|>), empty, liftA2, liftA, (<**>), many, some)
import qualified Data.Functor as Functor
import qualified Control.Applicative as Applicative
import Control.Applicative     (Const(Const), getConst)
import Control.Monad           (MonadPlus, mzero, mplus, liftM, liftM2, liftM3, join, (<$!>), forM)
--import Data.Functor            ((<$>), (<$), ($>), (<&>), void)
import GHC.ST                  (ST(..), runST)
import Control.Monad.ST.Unsafe (unsafeIOToST)
import Control.Monad.Reader    (ReaderT, ask, runReaderT, Reader, runReader, local)
import qualified Control.Monad.Reader as Reader
import Data.STRef              (STRef, writeSTRef, readSTRef, modifySTRef', newSTRef)
import System.IO.Unsafe        (unsafePerformIO)
import Data.IORef              (IORef, writeIORef, readIORef, newIORef)
import Data.Array              (Array, array)
import GHC.StableName          (StableName(..), makeStableName, hashStableName, eqStableName)
import Data.Hashable           (Hashable, hashWithSalt, hash)
import Data.HashMap.Lazy       (HashMap)
import qualified Data.HashMap.Lazy as HashMap
import Data.Map.Strict         (Map)
import qualified Data.Map.Strict as Map
import Data.Dependent.Map      (DMap)
import Data.GADT.Compare       (GEq, GCompare, gcompare, geq, (:~:)(Refl), GOrdering(..))
import qualified Data.Dependent.Map as DMap
import Data.Array.Unboxed      (UArray, listArray)
--import Data.Array.ST           (STArray)
import Data.Array.Base         (STUArray(..), unsafeAt, newArray_, unsafeRead, unsafeWrite, MArray, getNumElements, numElements)
import GHC.Prim                (Int#, Char#, StableName#, newByteArray#)
import GHC.Exts                (Int(..), Char(..), (-#), (+#), (*#))
import Unsafe.Coerce           (unsafeCoerce)
import Safe.Coerce             (coerce)
import Data.Maybe              (isJust, fromMaybe, fromJust)
import Data.List               (foldl')
import Language.Haskell.TH hiding (Match, match)
import Language.Haskell.TH.Syntax hiding (Match, match)
import Debug.Trace
import LiftPlugin

isDigit :: Char -> Bool
isDigit c
  |    c == '0' || c == '1' || c == '2' || c == '3'
    || c == '4' || c == '5' || c == '6' || c == '7'
    || c == '8' || c == '9' = True
  | otherwise = False


toDigit :: Char -> Int
toDigit c = fromEnum c - fromEnum '0'

digit :: Parser Int
digit = lift' toDigit <$> satisfy (lift' isDigit)

plus :: Parser (Int -> Int -> Int)
plus = char '+' $> lift' (+)

selectTest :: Parser (Either Int String)
selectTest = Parsley.pure (lift' (Left 10))

showi :: Int -> String
showi = show

instance Pure WQ where lift' x = WQ x [||x||]

-- AST
data WQ a = WQ { _val :: a, _code :: TExpQ a }
data Parser a where
  Pure          :: WQ a -> Parser a
  Satisfy       :: WQ (Char -> Bool) -> Parser Char
  (:<*>:)       :: Parser (a -> b) -> Parser a -> Parser b
  (:*>:)        :: Parser a -> Parser b -> Parser b
  (:<*:)        :: Parser a -> Parser b -> Parser a
  --(:>>=:)       :: Parser a -> (a -> Parser b) -> Parser b
  (:<|>:)       :: Parser a -> Parser a -> Parser a
  Empty         :: Parser a
  Try           :: Maybe Int -> Parser a -> Parser a
  LookAhead     :: Parser a -> Parser a
  Rec           :: Parser a -> Parser a
  NotFollowedBy :: Parser a -> Parser ()
  Branch        :: Parser (Either a b) -> Parser (a -> c) -> Parser (b -> c) -> Parser c
  Match         :: Parser a -> [WQ (a -> Bool)] -> [Parser b] -> Parser b
  ChainPre      :: Parser (a -> a) -> Parser a -> Parser a
  ChainPost     :: Parser a -> Parser (a -> a) -> Parser a

class IFunctor (f :: (* -> *) -> * -> *) where
  imap :: (forall i. a i -> b i) -> f a i -> f b i

class IFunctor m => IMonad (m :: (* -> *) -> * -> *) where
  ipure :: a i -> m a i
  ibind :: m a j ->(forall i. a i -> m b i) -> m b j

--data Free f i a = Var (a i) | Op (f (Free f i a) a)
data Free (f :: (* -> *) -> * -> *) (a :: * -> *) (i :: *) where
  Var :: a i -> Free f a i
  Op :: f (Free f a) i -> Free f a i

handle :: IFunctor f => (forall j. a j -> b j) -> (forall j. f b j -> b j) -> Free f a i -> b i
handle gen alg (Var x) = gen x
handle gen alg (Op x) = alg (imap (handle gen alg) x)

(/\) :: (a -> b) -> (a -> c) -> a -> (b, c)
(f /\ g) x = (f x, g x)

newtype Prod f g a = Prod {getProd :: (f a, g a)}
pandle :: IFunctor f => (forall j. a j -> b j) -> (forall j. f (Prod (Free f a) b) j -> b j) -> Free f a i -> b i
pandle gen alg (Var x) = gen x
pandle gen alg (Op x) = alg (imap (Prod . (id /\ (pandle gen alg))) x)

extract :: IFunctor f => (forall j. f a j -> a j) -> Free f a i -> a i
extract = handle id

instance IFunctor f => IFunctor (Free f) where
  imap f (Var x) = Var (f x)
  imap f (Op x) = Op (imap (imap f) x)

instance IFunctor f => IMonad (Free f) where
  ipure = Var
  ibind m f = handle f Op m

class Chain r k where
  (|>) :: (a -> Maybe r) -> (a -> k) -> a -> k
instance {-# OVERLAPPABLE #-} Chain a a where
  (|>) = liftM2 (flip fromMaybe)
instance {-# OVERLAPS #-} Chain a (Maybe a) where
  (|>) = liftM2 (Applicative.<|>)

data Unit k = Unit deriving Functor
data Void k deriving Functor

data Parser' (k :: * -> *) (a :: *) where
  Pure'          :: WQ a -> Parser' k a
  Satisfy'       :: WQ (Char -> Bool) -> Parser' k a
  (:<*>)       :: k (a -> b) -> k a -> Parser' k b
  (:*>)        :: k a -> k b -> Parser' k b
  (:<*)        :: k a -> k b -> Parser' k a
  --(:>>=:)       :: k a -> (a -> k b) -> Parser' k b
  (:<|>)       :: k a -> k a -> Parser' k a
  Empty'         :: Parser' a k
  Try'           :: Maybe Int -> k a -> Parser' k a
  LookAhead'     :: k a -> Parser' k a
  Rec'           :: k a -> Parser' k a
  ChainPre'      :: k (a -> a) -> k a -> Parser' k a
  NotFollowedBy' :: k a -> Parser' k ()
  Branch'        :: k (Either a b) -> k (a -> c) -> k (b -> c) -> Parser' k c

instance IFunctor Parser' where
  imap _ (Pure' x) = Pure' x
  imap _ (Satisfy' p) = Satisfy' p
  imap f (p :<*> q) = f p :<*> f q
  imap f (p :*> q) = f p :*> f q
  imap f (p :<* q) = f p :<* f q
  imap f (p :<|> q) = f p :<|> f q
  imap _ Empty' = Empty'
  imap f (Try' n p) = Try' n (f p)
  imap f (LookAhead' p) = LookAhead' (f p)
  imap f (Rec' p) = Rec' (f p)
  imap f (ChainPre' op p) = ChainPre' (f op) (f p)
  imap f (NotFollowedBy' p) = NotFollowedBy' (f p)
  imap f (Branch' b p q) = Branch' (f b) (f p) (f q)

convert :: Parser a -> Free Parser' Void a
convert (Pure x) = Op (Pure' x)
convert (Satisfy f) = Op (Satisfy' f)
convert (pf :<*>: px) = Op (convert pf :<*> convert px)
convert (p :*>: q) = Op (convert p :*> convert q)
convert (p :<*: q) = Op (convert p :<* convert q)
convert (p :<|>: q) = Op (convert p :<|> convert q)
convert Empty = Op Empty'
convert (Try n p) = Op (Try' n (convert p))
convert (LookAhead p) = Op (LookAhead' (convert p))
convert (Rec p) = Op (Rec' (convert p))
convert (ChainPre op p) = Op (ChainPre' (convert op) (convert p))
convert (NotFollowedBy p) = Op (NotFollowedBy' (convert p))
convert (Branch b p q) = Op (Branch' (convert b) (convert p) (convert q))

showAST' :: Free Parser' f a -> String
showAST' = getConst . handle (const (Const "")) (Const . alg)
  where
    alg :: Parser' (Const String) a -> String
    alg (Pure' x) = "(pure x)"
    alg (Satisfy' _) = "(satisfy f)"
    alg (Const pf :<*> Const px) = concat ["(", pf, " <*> ",  px, ")"]
    alg (Const p :*> Const q) = concat ["(", p, " *> ", q, ")"]
    alg (Const p :<* Const q) = concat ["(", p, " <* ", q, ")"]
    alg (Const p :<|> Const q) = concat ["(", p, " <|> ", q, ")"]
    alg Empty' = "empty"
    alg (Try' Nothing (Const p)) = concat ["(try ? ", p, ")"]
    alg (Try' (Just n) (Const p)) = concat ["(try ", show n, " ", p, ")"]
    alg (LookAhead' (Const p)) = concat ["(lookAhead ", p, ")"]
    alg (Rec' _) = "recursion point!"
    alg (ChainPre' (Const op) (Const p)) = concat ["(chainPre ", op, " ", p, ")"]
    alg (NotFollowedBy' (Const p)) = concat ["(notFollowedBy ", p, ")"]
    alg (Branch' (Const b) (Const p) (Const q)) = concat ["(branch ", b, " ", p, " ", q, ")"]

showAST :: Parser a -> String
showAST (Pure _) = "(pure x)"
showAST (Satisfy _) = "(satisfy f)"
showAST (pf :<*>: px) = concat ["(", showAST pf, " <*> ", showAST px, ")"]
showAST (p :*>: q) = concat ["(", showAST p, " *> ", showAST q, ")"]
showAST (p :<*: q) = concat ["(", showAST p, " <* ", showAST q, ")"]
showAST (p :<|>: q) = concat ["(", showAST p, " <|> ", showAST q, ")"]
showAST Empty = "empty"
showAST (Try Nothing p) = concat ["(try ? ", showAST p, ")"]
showAST (Try (Just n) p) = concat ["(try ", show n, " ", showAST p, ")"]
showAST (LookAhead p) = concat ["(lookAhead ", showAST p, ")"]
showAST (Rec _) = "recursion point!"
showAST (ChainPre op p) = concat ["(chainPre ", showAST op, " ", showAST p, ")"]
showAST (ChainPost op p) = concat ["(chainPost ", showAST op, " ", showAST p, ")"]
showAST (NotFollowedBy p) = concat ["(notFollowedBy ", showAST p, ")"]
showAST (Branch b p q) = concat ["(branch ", showAST b, " ", showAST p, " ", showAST q, ")"]
showAST (Match p fs qs) = concat ["(match ", showAST p, " ", show (map showAST qs), ")"]

-- Smart Constructors
{-instance Functor Parser where
  fmap = liftA
  x <$ p = p *> pure x
instance Applicative Parser where
  pure = Pure
  (<*>) = (:<*>:)
  (<*) = (:<*:)
  (*>) = (:*>:)
instance Monad Parser where
  return = Pure
  (>>=) = (:>>=:)
  (>>) = (*>)
instance Alternative Parser where
  empty = Empty
  (<|>) = (:<|>:)
  --many = Many
  some p = p <:> many p
instance MonadPlus Parser-}

fmap :: WQ (a -> b) -> Parser a -> Parser b
fmap f = (pure f <*>)

(<$>) :: WQ (a -> b) -> Parser a -> Parser b
(<$>) = fmap

void :: Parser a -> Parser ()
void p = p *> unit

(<$) :: WQ b -> Parser a -> Parser b
x <$ p = p *> pure x

($>) :: Parser a -> WQ b -> Parser b
($>) = flip (<$)

(<&>) :: Parser a -> WQ (a -> b) -> Parser b
(<&>) = flip fmap

pure :: WQ a -> Parser a
pure = Pure

(<*>) :: Parser (a -> b) -> Parser a -> Parser b
(<*>) = (:<*>:)

(<*) :: Parser a -> Parser b -> Parser a
(<*) = (:<*:)

(*>) :: Parser a -> Parser b -> Parser b
(*>) = (:*>:)

liftA2 :: WQ (a -> b -> c) -> Parser a -> Parser b -> Parser c
liftA2 f p q = f <$> p <*> q

empty :: Parser a
empty = Empty

(<|>) :: Parser a -> Parser a -> Parser a
(<|>) = (:<|>:)

many :: Parser a -> Parser [a]
many p = {-let manyp = p <:> manyp <|> pure (WQ [] [|| [] ||]) in manyp--}chainPre (lift' (:) <$> p) (pure (WQ [] [||[]||]))

some :: Parser a -> Parser [a]
some p = p <:> many p

skipMany :: Parser a -> Parser ()
skipMany p = let skipp = p *> skipp <|> unit in skipp

-- Additional Combinators
(<:>) :: Parser a -> Parser [a] -> Parser [a]
(<:>) = liftA2 (lift' (:))

(<**>) :: Parser a -> Parser (a -> b) -> Parser b
(<**>) = liftA2 (WQ (flip ($)) [|| (flip ($)) ||])

{-class Functor f => Monoidal f where
  unit :: f ()
  (<~>) :: f a -> f b -> f (a, b)
  (<~) :: f a -> f b -> f a
  p <~ q = fst <$> (p <~> q)
  (~>) :: f a -> f b -> f b
  p ~> q = snd <$> (p <~> q)-}

{-instance (Functor f, Applicative f) => Monoidal f where
  unit = pure ()
  (<~>) = liftA2 (,)
  (<~) = (<*)
  (~>) = (*>)-}

unit :: Parser ()
unit = pure (lift' ())

(<~>) :: Parser a -> Parser b -> Parser (a, b)
(<~>) = liftA2 (lift' (,))

(<~) :: Parser a -> Parser b -> Parser a
(<~) = (<*)

(~>) :: Parser a -> Parser b -> Parser b
(~>) = (*>)

--class (Monad p, Alternative p) => MonadParser p where
--  {-# MINIMAL (satisfy | item), notFollowedBy, lookAhead #-}
satisfy :: WQ (Char -> Bool) -> Parser Char
--satisfy p = item >>= (\x -> if p x then return x else empty)
item :: Parser Char
item = satisfy (WQ (const True) [|| const True ||])

  {-
  These combinators should adhere to the following laws:
    double negation: notFollowedBy . notFollowedBy         = lookAhead . void
    idempotence:     lookAhead . lookAhead                 = lookAhead
    right-identity:  notFollowedBy . lookAhead             = notFollowedBy
    left-identity:   lookAhead . notFollowedBy             = notFollowedBy
    transparency:    notFollowedBy p *>/<* notFollowedBy p = notFollowedBy p

  As a consequence of these laws:
    notFollowedBy eof = more
    notFollowedBy more = eof
  -}
lookAhead :: Parser a -> Parser a
notFollowedBy :: Parser a -> Parser ()

  -- Auxillary functions
char :: Char -> Parser Char
string :: String -> Parser String
string = foldr (<:>) (pure (lift' [])) . map char
token :: String -> Parser String
token = try . string
eof :: Parser ()
eof = notFollowedBy item
more :: Parser ()
more = lookAhead (void item)

--instance MonadParser Parser where
satisfy = Satisfy
char c = lift' c <$ satisfy (WQ (== c) [||(== c)||])
lookAhead = LookAhead
---notFollowedBy p = try (join ((try p *> return empty) <|> return unit))
notFollowedBy = NotFollowedBy

try :: Parser a -> Parser a
try = Try Nothing

optional :: Parser a -> Parser ()
optional p = void p <|> unit

choice :: [Parser a] -> Parser a
choice = foldr (<|>) empty

bool :: a -> a -> Bool -> a
bool x y True  = x
bool x y False = y

constp :: Parser a -> Parser (b -> a)
constp = (lift' const <$>)

(<?|>) :: Parser Bool -> (Parser a, Parser a) -> Parser a
cond <?|> (p, q) = branch (WQ (bool (Left ()) (Right ())) [||bool (Left ()) (Right ())||] <$> cond) (constp p) (constp q)

(>?>) :: Parser a -> WQ (a -> Bool) -> Parser a
p >?> (WQ f qf) = select (WQ g qg <$> p) empty
  where
    g x = if f x then Right x else Left ()
    qg = [||\x -> if $$qf x then Right x else Left ()||]

_match :: Eq a => a -> Either a b -> Either () (Either a b)
_match _ (Right y) = Right (Right y)
_match x (Left y)
  | x == y = Left ()
  | otherwise = Right (Left y)

match :: (Eq a, Lift a) => [a] -> Parser a -> (a -> Parser b) -> Parser b
match vs p f = Match p (map (\v -> WQ (== v) [||(== v)||]) vs) (map f vs)

(||=) :: forall a b. (Enum a, Bounded a, Eq a, Lift a) => Parser a -> (a -> Parser b) -> Parser b
p ||= f = match [minBound..maxBound] p f

branch :: Parser (Either a b) -> Parser (a -> c) -> Parser (b -> c) -> Parser c
branch = Branch

when :: Parser Bool -> Parser () -> Parser ()
when p q = p <?|> (q, unit)

while :: Parser Bool -> Parser ()
while x = let w = when x w in w

select :: Parser (Either a b) -> Parser (a -> b) -> Parser b
select p q = branch p q (pure (lift' id))

fromMaybeP :: Parser (Maybe a) -> Parser a -> Parser a
fromMaybeP pm px = select (WQ (maybe (Left ()) Right) [||maybe (Left ()) Right||] <$> pm) (constp px)

chainl1 :: Parser a -> Parser (a -> a -> a) -> Parser a
chainl1 p op = chainPost p (lift' flip <$> op <*> p)
--chainl1 p op = let rest = (lift' flip >*< lift' (.) <$> (lift' flip <$> op <*> p) <*> rest) <|> pure (lift' id) in p <**> rest

chainPre :: Parser (a -> a) -> Parser a -> Parser a
chainPre = ChainPre

chainPost :: Parser a -> Parser (a -> a) -> Parser a
chainPost = ChainPost--p op = lift' Parsley.foldl' >*< (lift' flip >*< lift' ($)) <$> p <*> many op

data StableParserName = forall a. StableParserName (StableName# (Parser a))
data GenParser = forall a. GenParser (Parser a)
instance Eq StableParserName where (StableParserName n) == (StableParserName m) = eqStableName (StableName n) (StableName m)
instance Hashable StableParserName where
  hash (StableParserName n) = hashStableName (StableName n)
  hashWithSalt salt (StableParserName n) = hashWithSalt salt (StableName n)

preprocess :: Parser a -> Parser a
preprocess !p = trace "preprocessing" $ unsafePerformIO (runReaderT (preprocess' p) (HashMap.empty))
  where
    preprocess' :: Parser a -> ReaderT (HashMap StableParserName GenParser) IO (Parser a)
    -- Force evaluation of p to ensure that the stableName is correct first time
    preprocess' !p =
      do !seen <- ask
         (StableName _name) <- Reader.lift (makeStableName p)
         let !name = StableParserName _name
         case HashMap.lookup name seen of
           Just (GenParser q) -> return $! (Rec (coerce q))
           Nothing -> mdo q <- local (HashMap.insert name (GenParser q)) (preprocess'' p)
                          return $! q
    preprocess'' :: Parser a -> ReaderT (HashMap StableParserName GenParser) IO (Parser a)
    preprocess'' !(pf :<*>: px)     = liftM optimise (liftM2 (:<*>:)  (preprocess' pf) (preprocess' px))
    preprocess'' !(p :*>: q)        = liftM optimise (liftM2 (:*>:)   (preprocess' p)  (preprocess' q))
    preprocess'' !(p :<*: q)        = liftM optimise (liftM2 (:<*:)   (preprocess' p)  (preprocess' q))
    preprocess'' !(p :<|>: q)       = liftM optimise (liftM2 (:<|>:)  (preprocess' p)  (preprocess' q))
    preprocess'' !Empty             = return Empty
    preprocess'' !(Try n p)         = liftM optimise (liftM (Try n) (preprocess' p))
    preprocess'' !(LookAhead p)     = liftM optimise (liftM LookAhead (preprocess' p))
    preprocess'' !(NotFollowedBy p) = liftM optimise (liftM NotFollowedBy (preprocess' p))
    preprocess'' !(Branch b p q)    = liftM optimise (liftM3 Branch (preprocess' b) (preprocess' p) (preprocess' q))
    preprocess'' !(Match p fs qs)   = liftM optimise (liftM3 Match (preprocess' p) (return fs) (traverse preprocess' qs))
    preprocess'' !(ChainPre op p)   = liftM2 ChainPre (preprocess' op) (preprocess' p)
    preprocess'' !(ChainPost p op)  = liftM2 ChainPost (preprocess' p) (preprocess' op)
    preprocess'' !p                 = return p

-- pronounced quapp
(>*<) :: WQ (a -> b) -> WQ a -> WQ b
WQ f qf >*< WQ x qx = WQ (f x) [||$$qf $$qx||]
infixl 9 >*<

optimise :: Parser a -> Parser a
-- DESTRUCTIVE OPTIMISATION
-- Right Absorption Law: empty <*> u = empty
optimise (Empty :<*>: _)           = empty
-- Failure Weakening Law: u <*> empty = u *> empty
optimise (u :<*>: Empty)           = optimise (u *> empty)
-- Right Absorption Law: empty *> u = empty
optimise (Empty :*>: _)            = empty
-- Right Absorption Law: empty <* u = empty
optimise (Empty :<*: _)            = empty
-- Failure Weakening Law: u <* empty = u *> empty
optimise (u :<*: Empty)            = u *> empty
-- Right Absorption Law: empty >>= f = empty
--optimise (Empty :>>=: f)           = Empty
-- APPLICATIVE OPTIMISATION
-- Homomorphism Law: pure f <*> pure x = pure (f x)
optimise (Pure f :<*>: Pure x) = pure (f >*< x)
-- NOTE: This is basically a shortcut, it can be caught by the Composition Law and Homomorphism law
optimise (Pure f :<*>: (Pure g :<*>: p)) = optimise (lift' (.) >*< f >*< g <$> p)
-- Composition Law: u <*> (v <*> w) = pure (.) <*> u <*> v <*> w
optimise (u :<*>: (v :<*>: w))     = optimise (optimise (optimise (pure (lift' (.)) <*> u) <*> v) <*> w)
-- Reassociation Law 1: (u *> v) <*> w = u *> (v <*> w)
optimise ((u :*>: v) :<*>: w)      = optimise (u *> (optimise (v <*> w)))
-- Interchange Law: u <*> pure x = pure ($ x) <*> u
optimise (u :<*>: Pure x)          = optimise (lift' flip >*< lift' ($) >*< x <$> u)
-- Reassociation Law 2: u <*> (v <* w) = (u <*> v) <* w
optimise (u :<*>: (v :<*: w))      = optimise (optimise (u <*> v) <* w)
-- Reassociation Law 3: u <*> (v *> pure x) = (u <*> pure x) <* v
optimise (u :<*>: (v :*>: Pure x)) = optimise (optimise (u <*> pure x) <* v)
-- ALTERNATIVE OPTIMISATION
-- Left Catch Law: pure x <|> u = pure x
optimise (Pure x :<|>: _)          = pure x
-- Left Neutral Law: empty <|> u = u
optimise (Empty :<|>: u)           = u
-- Right Neutral Law: u <|> empty = u
optimise (u :<|>: Empty)           = u
-- Associativity Law: (u <|> v) <|> w = u <|> (v <|> w)
optimise ((u :<|>: v) :<|>: w)     = u <|> optimise (v <|> w)
-- MONADIC OPTIMISATION
-- Left Identity Law: pure x >>= f = f x
--optimise (Pure x :>>=: f)          = f x
-- Reassociation Law 4: (u *> v) >>= f = u *> (v >>= f)
--optimise ((u :*>: v) :>>=: f)      = optimise (u *> optimise (v >>= f))
-- SEQUENCING OPTIMISATION
-- Identity law: pure x *> u = u
optimise (Pure _ :*>: u)           = u
-- Identity law: (u *> pure x) *> v = u *> v
optimise ((u :*>: Pure _) :*>: v)  = u *> v
-- Associativity Law: u *> (v *> w) = (u *> v) *> w
optimise (u :*>: (v :*>: w))       = optimise (optimise (u *> v) *> w)
-- Identity law: u <* pure x = u
optimise (u :<*: Pure _) = u
-- Identity law: u <* (v *> pure x) = u <* v
optimise (u :<*: (v :*>: Pure _))  = optimise (u <* v)
-- Commutativity Law: pure x <* u = u *> pure x
optimise (Pure x :<*: u)           = optimise (u *> pure x)
-- Associativity Law (u <* v) <* w = u <* (v <* w)
optimise ((u :<*: v) :<*: w)       = optimise (u <* optimise (v <* w))
-- Pure lookahead: lookAhead (pure x) = pure x
optimise (LookAhead (Pure x))      = pure x
-- Dead lookahead: lookAhead empty = empty
optimise (LookAhead Empty)         = empty
-- Pure negative-lookahead: notFollowedBy (pure x) = empty
optimise (NotFollowedBy (Pure _))  = empty
-- Dead negative-lookahead: notFollowedBy empty = unit
optimise (NotFollowedBy Empty)     = unit
-- Double Negation Law: notFollowedBy . notFollowedBy = lookAhead . try . void
optimise (NotFollowedBy (NotFollowedBy p)) = optimise (lookAhead (void (try p)))
-- Zero Consumption Law: notFollowedBy (try p) = notFollowedBy p
optimise (NotFollowedBy (Try _ p)) = optimise (notFollowedBy p)
-- Idempotence Law: lookAhead . lookAhead = lookAhead
optimise (LookAhead (LookAhead p)) = lookAhead p
-- Right Identity Law: notFollowedBy . lookAhead = notFollowedBy
optimise (NotFollowedBy (LookAhead p)) = optimise (notFollowedBy p)
-- Left Identity Law: lookAhead . notFollowedBy = notFollowedBy
optimise (LookAhead (NotFollowedBy p)) = notFollowedBy p
-- Transparency Law: notFollowedBy (try p <|> q) = notFollowedBy p *> notFollowedBy q
optimise (NotFollowedBy (Try _ p :<|>: q)) = optimise (optimise (notFollowedBy p) *> optimise (notFollowedBy q))
-- Distributivity Law: lookAhead p <|> lookAhead q = lookAhead (p <|> q)
optimise (LookAhead p :<|>: LookAhead q) = optimise (lookAhead (optimise (p <|> q)))
-- Absorption Law: p <*> lookAhead (q *> pure x) = (p <*> pure x) <* lookAhead q
optimise (p :<*>: LookAhead (q :*>: Pure x)) = optimise (optimise (p <*> pure x) <* optimise (lookAhead q))
-- Absorption Law: p <*> notFollowedBy q = (p <*> unit) <* notFollowedBy q
optimise (p :<*>: NotFollowedBy q) = optimise (optimise (p <*> unit) <* notFollowedBy q)
-- Idempotence Law: notFollowedBy (p *> pure x) = notFollowedBy p
optimise (NotFollowedBy (p :*>: Pure _)) = optimise (notFollowedBy p)
-- Idempotence Law: notFollowedBy (f <$> p) = notFollowedBy p
optimise (NotFollowedBy (Pure _ :<*>: p)) = optimise (notFollowedBy p)
optimise (Try _ (Pure x))          = pure x
optimise (Try _ Empty)             = empty
optimise (Try Nothing p)           = Try (constantInput p) p
-- pure Left law: branch (pure (Left x)) p q = p <*> pure x
optimise (Branch (Pure (WQ (Left x) ql)) p _) = optimise (p <*> pure (WQ x qx)) where qx = [||case $$ql of Left x -> x||]
-- pure Right law: branch (pure (Right x)) p q = q <*> pure x
optimise (Branch (Pure (WQ (Right x) ql)) _ q) = optimise (q <*> pure (WQ x qx)) where qx = [||case $$ql of Right x -> x||]
-- Generalised Identity law: branch b (pure f) (pure g) = either f g <$> b
optimise (Branch b (Pure f) (Pure g)) = optimise (lift' either >*< f >*< g <$> b)
-- Interchange law: branch (x *> y) p q = x *> branch y p q
optimise (Branch (x :*>: y) p q)   = optimise (x *> optimise (branch y p q))
-- Negated Branch law: branch b p empty = branch (swapEither <$> b) empty p
optimise (Branch b p Empty) = branch (WQ (either Right Left) [||either Right Left||] <$> b) empty p
-- Branch Fusion law: branch (branch b empty (pure f)) empty k = branch (g <$> b) empty k where g is a monad transforming (>>= f)
optimise (Branch (Branch b Empty (Pure (WQ f qf))) Empty k) = optimise (branch (optimise (WQ g qg <$> b)) empty k)
  where
    g (Left _) = Left ()
    g (Right x) = case f x of
      Left _ -> Left ()
      Right x -> Right x
    qg = [||\case Left _ -> Left ()
                  Right x -> case $$qf x of
                               Left _ -> Left ()
                               Right y -> Right y||]
-- Distributivity Law: f <$> branch b p q = branch b ((f .) <$> p) ((f .) <$> q)
optimise (Pure f :<*>: Branch b p q)   = optimise (branch b (optimise (lift' (.) >*< f <$> p)) (optimise (lift' (.) >*< f <$> q)))
-- pure Match law: match vs (pure x) f = if elem x vs then f x else empty
optimise (Match (Pure (WQ x _)) fs qs) = foldr (\(f, q) k -> if _val f x then q else k) empty (zip fs qs)
-- Generalised Identity Match law: match vs p (pure . f) = f <$> (p >?> flip elem vs)
optimise (Match p fs qs)
  | all (\case {Pure _ -> True; _ -> False}) qs = optimise (WQ apply qapply <$> (p >?> WQ validate qvalidate))
    where apply x    = foldr (\(f, Pure y) k -> if _val f x then _val y else k) (error "whoopsie") (zip fs qs)
          qapply     = foldr (\(f, Pure y) k -> [||\x -> if $$(_code f) x then $$(_code y) else $$k x||]) ([||const (error "whoopsie")||]) (zip fs qs)
          validate x = foldr (\f b -> _val f x || b) False fs
          qvalidate  = foldr (\f k -> [||\x -> $$(_code f) x || $$k x||]) [||const False||] fs
-- Distributivity Law: f <$> match vs p g = match vs p ((f <$>) . g)
optimise (Pure f :<*>: Match p fs qs)  = Match p fs (map (optimise . (f <$>)) qs)
optimise p                             = p

-- NOTE: Distributivity Law : branch (pure x) (p *> q) (r *> s) = branch (pure x) p r *> branch (pure x) q s

--optimise'' :: Free Parser' Void a -> Free Parser' Void a
--optimise'' (Op x) = optimise' x

optimise' :: Parser' (Free Parser' f) a -> Free Parser' f a
optimise' (Op Empty' :<*> _) = Op Empty'
optimise' (u :<*> Op Empty') = Op (u :*> Op Empty')
optimise' (Op Empty' :*> _)  = Op Empty'
optimise' (Op Empty' :<* _)  = Op Empty'
optimise' (u :<* Op Empty')  = Op (u :*> Op Empty')
optimise' (Op (Pure' (WQ f qf)) :<*> Op (Pure' (WQ x qx))) = Op (Pure' (WQ (f x) [|| $$qf $$qx ||]))
optimise' (Op (Pure' (WQ f qf)) :<*> Op (Op (Pure' (WQ g qg)) :<*> p)) = optimise' (Op (Pure' (WQ (f . g) [|| $$qf . $$qg ||])) :<*> p)
optimise' (u :<*> Op (v :<*> w))          = optimise' (optimise' (optimise' (Op (Pure' (WQ (.) [||(.)||])) :<*> u) :<*> v) :<*> w)
optimise' (Op (u :*> v) :<*> w)           = optimise' (u :*> (optimise' (v :<*> w)))
optimise' (u :<*> Op (Pure' (WQ x qx)))     = optimise' (Op (Pure' (WQ ($ x) [|| \f -> f $$qx ||])) :<*> u)
optimise' (u :<*> Op (v :<* w))           = optimise' (optimise' (u :<*> v) :<* w)
optimise' (u :<*> Op (v :*> Op (Pure' x))) = optimise' (optimise' (u :<*> Op (Pure' x)) :<* v)
optimise' (Op (Pure' x) :<|> _)             = Op (Pure' x)
optimise' (Op Empty' :<|> u)                = u
optimise' (u :<|> Op Empty')                = u
optimise' (Op (u :<|> v) :<|> w)          = Op (u :<|> optimise' (v :<|> w))
optimise' (Op (Pure' _) :*> u)              = u
optimise' (Op (u :*> Op (Pure' _)) :*> v)  = Op (u :*> v)
optimise' (u :*> Op (v :*> w))            = optimise' (optimise' (u :*> v) :*> w)
optimise' (u :<* Op (Pure' _))              = u
optimise' (u :<* Op (v :*> Op (Pure' _)))  = optimise' (u :<* v)
optimise' (Op (Pure' x) :<* u)              = optimise' (u :*> Op (Pure' x))
optimise' (Op (u :<* v) :<* w)            = optimise' (u :<* optimise' (v :<* w))
optimise' (Try' _ (Op (Pure' x)))            = Op (Pure' x)
optimise' (Try' _ (Op Empty'))               = Op Empty'
optimise' (Try' Nothing p)                  = Op (Try' (constantInput' p) p)
optimise' p                                = Op p

constantInput :: Parser a -> Maybe Int
constantInput (Pure _) = Just 0
constantInput (Satisfy _) = Just 1
constantInput (p :<*>: q) = constantInput p <+> constantInput q
constantInput (p :*>: q) = constantInput p <+> constantInput q
constantInput (p :<*: q) = constantInput p <+> constantInput q
constantInput (Try n _ :<|>: q) = n <==> constantInput q
constantInput Empty = Just 0
constantInput (Try n _) = n
constantInput (LookAhead p) = constantInput p
constantInput (NotFollowedBy p) = constantInput p
constantInput (Branch b p q) = constantInput b <+> (constantInput p <==> constantInput q)
constantInput (Match p _ qs) = constantInput p <+> (foldr1 (<==>) (map constantInput qs))
constantInput _ = Nothing

constantInput' :: Free Parser' f a -> Maybe Int
constantInput' = getConst . pandle (const (Const Nothing)) (alg1 |> (Const . alg2 . imap (snd . getProd)))
  where
    alg1 :: Parser' (Prod (Free Parser' f) (Const (Maybe Int))) a -> Maybe (Const (Maybe Int) a)
    alg1 (Prod (Op (Try' _ _), Const n) :<|> Prod (_, Const q)) = Just (Const (n <==> q))
    alg1 _ = Nothing
    alg2 :: Parser' (Const (Maybe Int)) a -> Maybe Int
    alg2 (Pure' _) = Just 0
    alg2 (Satisfy' _) = Just 1
    alg2 (Const p :<*> Const q) = p <+> q
    alg2 (Const p :*> Const q) = p <+> q
    alg2 (Const p :<* Const q) = p <+> q
    alg2 Empty' = Just 0
    alg2 (Try' n _) = n
    alg2 (LookAhead' (Const p)) = p
    alg2 (NotFollowedBy' (Const p)) = p
    alg2 (Branch' (Const b) (Const p) (Const q)) = b <+> (p <==> q)
    alg2 _ = Nothing

(<+>) :: (Num a, Monad m) => m a -> m a -> m a
(<+>) = liftM2 (+)
(<==>) :: Eq a => Maybe a -> Maybe a -> Maybe a
(Just x) <==> (Just y)
  | x == y    = Just x
  | otherwise = Nothing
_ <==> _ = Nothing

newtype ΣVar a = ΣVar Int deriving Show
newtype MVar xs ks a = MVar Int deriving Show
data M xs ks a where
  Halt          :: M '[a] ks a
  Ret           :: M (b ': xs) ((b ': xs) ': ks) a
  Push          :: WQ x -> !(M (x ': xs) ks a) -> M xs ks a
  Pop           :: !(M xs ks a) -> M (b ': xs) ks a
  Lift2         :: !(WQ (x -> y -> z)) -> !(M (z ': xs) ks a) -> M (y ': x ': xs) ks a
  Sat           :: WQ (Char -> Bool) -> !(M (Char ': xs) ks a) -> M xs ks a
  Call          :: M xs ((b ': xs) ': ks) a -> MVar xs ((b ': xs) ': ks) a -> !(M (b ': xs) ks a) -> M xs ks a
  MuCall        :: MVar xs ((b ': xs) ': ks) a -> !(M (b ': xs) ks a) -> M xs ks a
  Empt          :: M xs ks a
  Commit        :: !Bool -> !(M xs ks a) -> M xs ks a
  SoftFork      :: !(Maybe Int) -> !(M xs ks a) -> M xs ks a -> M xs ks a
  HardFork      :: !(M xs ks a) -> M xs ks a -> M xs ks a
  Attempt       :: !(Maybe Int) -> !(M xs ks a) -> M xs ks a
  Look          :: !(M xs ks a) -> M xs ks a
  NegLook       :: !(M xs ks a) -> !(M xs ks a) -> M xs ks a
  Restore       :: !(M xs ks a) -> M xs ks a
  Case          :: !(M (x ': xs) ks a) -> !(M (y ': xs) ks a) -> M (Either x y ': xs) ks a
  Choices       :: ![WQ (x -> Bool)] -> ![M xs ks a] -> M (x ': xs) ks a
  ChainIter     :: !(ΣVar x) -> !(MVar xs ks a) -> M ((x -> x) ': xs) ks a
  --ChainPreInit  :: !(ΣVar (x -> x)) -> !(M xs ks a) -> !(MVar xs ks a) -> !(M ((x -> x) ': xs) ks a) -> M xs ks a
  ChainInit :: !(WQ x) -> !(ΣVar x) -> !(M xs ks a) -> !(MVar xs ks a) -> M (x ': xs) ks a -> M (x ': xs) ks a

instance Show (M xs ks a) where
  show Halt = "Halt"
  show Ret = "Ret"
  show (Call m v k) = "{Call (" ++ show v ++ ") " ++ show m ++ " " ++ show k ++ "}"
  show (MuCall v k) = "(μCall (" ++ show v ++ ") " ++ show k ++ ")"
  show (Push _ k) = "(Push x " ++ show k ++ ")"
  show (Pop k) = "(Pop " ++ show k ++ ")"
  show (Lift2 _ k) = "(Lift2 f " ++ show k ++ ")"
  show (Sat _ k) = "(Sat f " ++ show k ++ ")"
  show Empt = "Empt"
  show (Commit True k) = "(Commit end " ++ show k ++ ")"
  show (Commit False k) = "(Commit " ++ show k ++ ")"
  show (SoftFork Nothing p q) = "(SoftFork " ++ show p ++ " " ++ show q ++ ")"
  show (SoftFork (Just n) p q) = "(SoftFork " ++ show n ++ " " ++ show p ++ " " ++ show q ++ ")"
  show (HardFork p q) = "(HardFork " ++ show p ++ " " ++ show q ++ ")"
  show (Attempt Nothing k) = "(Try " ++ show k ++ ")"
  show (Attempt (Just n) k) = "(Try " ++ show n ++ " " ++ show k ++ ")"
  show (Look k) = "(Look " ++ show k ++ ")"
  show (NegLook m k) = "(NegLook " ++ show m ++ " " ++ show k ++ ")"
  show (Restore k) = "(Restore " ++ show k ++ ")"
  show (Case m k) = "(Case " ++ show m ++ " " ++ show k ++ ")"
  show (Choices _ ks) = "(Choices " ++ show ks ++ ")"
  show (ChainIter σ v) = "(ChainIter (" ++ show σ ++ ") (" ++ show v ++ "))"
  show (ChainInit _ σ m v k) = "{ChainInit (" ++ show σ ++ ") (" ++ show v ++ ") " ++ show m ++ " " ++ show k ++ "}"

compile :: Parser a -> (M '[] '[] a, [State])
compile !p = trace (show m) (m, vss)
  where (m, vss) = unsafePerformIO (do σs <- newIORef []
                                       m <- runReaderT (compile' (trace (showAST p) p) Halt) (HashMap.empty, 0, σs)
                                       vss <- readIORef σs
                                       return $! (m, vss))

(><) :: (a -> c) -> (b -> d) -> (a, b, x) -> (c, d, x)
(f >< g) (x, y, z) = (f x, g y, z)

type IMVar = Int
data State = forall a. State a (TExpQ a) (ΣVar a)
type ΣVars = IORef [State]
compile' :: Parser a -> M (a ': xs) ks b -> ReaderT (HashMap StableParserName IMVar, IMVar, ΣVars) IO (M xs ks b)
compile' !(Pure x) !m          = do return $! (Push x m)
compile' !(Satisfy p) !m       = do return $! (Sat p m)
compile' !(pf :<*>: px) !m     = do !pxc <- compile' px (Lift2 (lift' ($)) m); compile' pf pxc
compile' !(p :*>: q) !m        = do !qc <- compile' q m; compile' p (Pop qc)
compile' !(p :<*: q) !m        = do !qc <- compile' q (Pop m); compile' p qc
compile' !Empty !m             = do return $! Empt
compile' !(Try n p :<|>: q) !m = do liftM2 (SoftFork n) (compile' p (Commit (isJust n) m)) (compile' q m)
compile' !(p :<|>: q) !m       = do liftM2 HardFork (compile' p (Commit False m)) (compile' q m)
--compile' !(p :>>=: f) !m       = do compile' p (Bind f')
--  where f' x = runST $ (newSTRef HashMap.empty) >>= runReaderT (compile' (preprocess (f x)) m)
compile' !(Try n p) !m         = do liftM (Attempt n) (compile' p (Commit (isJust n) m))
compile' !(LookAhead p) !m     = do liftM Look (compile' p (Restore m))
compile' !(NotFollowedBy p) !m = do liftM2 NegLook (compile' p (Restore Empt)) (return (Push (lift' ()) m))
compile' !(Branch b p q) !m    = do !pc <- compile' p (Lift2 (WQ (flip ($)) [||flip ($)||]) m)
                                    !qc <- compile' q (Lift2 (WQ (flip ($)) [||flip ($)||]) m)
                                    compile' b (Case pc qc)
compile' !(Match p fs qs) !m   = do !qcs <- traverse (flip compile' m) qs
                                    compile' p (Choices fs qcs)
compile' !(Rec !p) !m          =
  do (StableName _name) <- Reader.lift (makeStableName p)
     (seen, v, _) <- ask
     let !name = StableParserName _name
     case HashMap.lookup name seen of
       Just v' -> do return $! MuCall (MVar v') m
       Nothing -> do n <- local (HashMap.insert name v >< (+1)) (compile' p Ret)
                     return $! Call n (MVar v) m
compile' (ChainPre op p) m =
  do (_, v, rσs) <- ask
     σs <- Reader.lift (readIORef rσs)
     let σ = case σs of
               [] -> ΣVar 0
               (State _ _ (ΣVar x)):_ -> ΣVar (x+1)
     Reader.lift (writeIORef rσs (State id [|| id ||] σ:σs))
     opc <- local (id >< (+1)) (compile' op (Lift2 (lift' ($)) (ChainIter σ (MVar v))))
     pc <- local (id >< (+1)) (compile' p (Lift2 (lift' ($)) m))
     return $! Push (lift' id) (ChainInit (lift' id) σ (Push (lift' flip >*< lift' (.)) opc) (MVar v) pc)
{-compile' (ChainPost (Pure x) op) m =
  do (_, v, rσs) <- ask
     σs <- Reader.lift (readIORef rσs)
     let σ = case σs of
               [] -> ΣVar 0
               (State _ _ (ΣVar x)):_ -> ΣVar (x+1)
     Reader.lift (writeIORef rσs (State (_val x) (_code x) σ:σs))
     opc <- local (id >< (+1)) (compile' op (ChainPostIter σ (MVar v)))
     let m' = ChainInit x σ opc (MVar v) m
     return $! Push x m'-}
compile' (ChainPost p op) m =
  do (_, v, rσs) <- ask
     σs <- Reader.lift (readIORef rσs)
     let σ = case σs of
               [] -> ΣVar 0
               (State _ _ (ΣVar x)):_ -> ΣVar (x+1)
     Reader.lift (writeIORef rσs (State Nothing [|| Nothing ||] σ:σs))
     opc <- local (id >< (+1)) (compile' op (Lift2 (lift' ($)) (ChainIter σ (MVar v))))
     let m' = ChainInit (WQ Nothing [||Nothing||]) σ (Push (lift' (<$!>)) opc) (MVar v) (Lift2 (lift' ($)) m)
     pc <- local (id >< (+1)) (compile' p (Lift2 (lift' ($)) m'))
     return $! Push (lift' fromJust) (Push (lift' Just) pc)

data SList a = !a ::: !(SList a) | SNil
data HList xs where
  HNil :: HList '[]
  HCons :: a -> !(HList as) -> HList (a ': as)
data K s ks a where
  KNil :: K s '[] a
  KCons :: !(Input -> X xs -> K s ks a -> O# -> H s a -> CIdx# -> C s -> Σ s -> D# -> ST s (Maybe a)) -> !(K s ks a) -> K s (xs ': ks) a

instance Show (K s ks a) where
  show KNil = "KNil"
  show (KCons _ ks) = "(KCons " ++ show ks ++ ")"

type Input = UArray Int Char
type QInput = TExpQ Input
newtype H s a = H (SList (O# -> H s a -> CIdx# -> C s -> D# -> ST s (Maybe a)))
type QH s a = TExpQ (H s a)
type X = HList
type QX xs = TExpQ (X xs)
type QK s ks a = TExpQ (K s ks a)
type CIdx = Int
type CIdx# = Int#
type QCIdx = TExpQ CIdx
type C s = STUArray s Int Int
type QC s = TExpQ (C s)
type O = Int
type O# = Int#
type QO = TExpQ O
data Σ s = Σ { save :: ST s (), restore :: ST s (), rollback :: D -> ST s () }
type D = Int
type D# = Int#
type QD = TExpQ D
type QΣ s = TExpQ (Σ s)
type QST s a = TExpQ (ST s a)
newtype QSTRef s a = QSTRef (TExpQ (STRef s (SList a)))

data Γ s xs ks a = Γ { input :: QInput
                     , xs    :: QX xs
                     , ks    :: QK s ks a
                     , o     :: QO
                     , hs    :: QH s a
                     , cidx  :: QCIdx
                     , cs    :: QC s
                     , σs    :: QΣ s
                     , d     :: QD }

double :: STUArray s Int Int -> ST s (STUArray s Int Int)
double !arr =
  do !sz <- getNumElements arr
     resize arr sz (sz * 2)

resize :: STUArray s Int Int -> Int -> Int -> ST s (STUArray s Int Int)
resize arr old (I# new) =
  do !arr' <- ST (\s -> case newByteArray# (new *# 8#) s of (# s', arr'# #) -> (# s', STUArray 0 ((I# new)-1) (I# new) arr'# #))
     let copy !from !to !n = do !x <- unsafeRead from n
                                unsafeWrite to n x
                                if n == 0 then return $! ()
                                else copy from to $! (n-1)
                             in copy arr arr' $! (old-1)
     return $! arr'

makeX :: ST s (X '[])
makeX = return $! HNil
{-# INLINE pushX #-}
pushX :: a -> X xs -> X (a ': xs)
pushX = HCons
{-# INLINE popX #-}
popX :: X (a ': xs) -> (a, X xs)
popX (HCons x xs) = (x, xs)
{-# INLINE popX_ #-}
popX_ :: X (a ': xs) -> X xs
popX_ (HCons x xs) = xs
{-# INLINE pokeX #-}
pokeX :: a -> X (a ': xs) -> X (a ': xs)
pokeX y (HCons x xs) = HCons y xs
{-# INLINE modX #-}
modX :: (a -> b) -> X (a ': xs) -> X (b ': xs)
modX f (HCons x xs) = HCons (f x) xs
{-# INLINE peekX #-}
peekX :: X (a ': xs) -> a
peekX (HCons x xs) = x

makeK :: ST s (K s '[] a)
makeK = return $! KNil
suspend :: M xs ks a -> Ctx s a -> QK s ks a -> QK s (xs ': ks) a
suspend m ctx ks =
  [|| KCons (\input xs ks o hs cidx cs σs d ->
    $$(runReader (eval' m (Γ [|| input ||] [|| xs ||] [||ks||] [||I# o||] [||hs||] [||I# cidx||] [||cs||] [||σs||] [||I# d||])) ctx)) $$ks ||]
resume :: Γ s xs (xs ': ks) a -> QST s (Maybe a)
resume (Γ input xs ks o hs cidx cs σs d) =
  [|| let ks' = bug ($$ks) :: forall s xs ks a. K s (xs ': ks) a in
        case ks' of
          (KCons k ks) -> (bug k) $$input $$(bug xs) (bug ks) $$o $$hs $$cidx $$cs $$σs $$d
  ||]

makeH :: ST s (H s a)
makeH = return $! (H SNil)
pushH :: (O# -> H s a -> CIdx# -> C s -> D# -> ST s (Maybe a)) -> H s a -> H s a
pushH !h !(H hs) = H (h:::hs)
{-# INLINE popH_ #-}
popH_ :: H s a -> H s a
popH_ !(H (_:::hs)) = H hs

makeC :: ST s (CIdx, C s)
makeC = do cs <- newArray_ (0, 3)
           return $! (-1, cs)
{-# INLINE pushC #-}
pushC :: O -> CIdx -> C s -> ST s (CIdx, C s)
pushC c i !cs = let !j = i + 1 in
  do sz <- getNumElements cs
     if j == sz then do !cs' <- double cs
                        unsafeWrite cs' j c
                        return $! (j, cs')
     else do unsafeWrite cs j c; return $! (j, cs)
popC :: CIdx -> C s -> ST s (O, CIdx)
popC !i !cs = do !c <- unsafeRead cs i; return $! (c, i - 1)
{-# INLINE popC_ #-}
popC_ :: CIdx -> CIdx
popC_ !i = i - 1
pokeC :: O -> CIdx -> C s -> ST s ()
pokeC !c !i !cs = unsafeWrite cs i c

nextSafe :: Bool -> QInput -> QO -> TExpQ (Char -> Bool) -> (QO -> TExpQ Char -> QST s (Maybe a)) -> QST s (Maybe a) -> QST s (Maybe a)
nextSafe True input o p good bad = [|| let !c = unsafeAt $$input $$o in if $$p c then $$(good [|| $$o + 1 ||] [|| c ||]) else $$bad ||]
nextSafe False input o p good bad = [||
    let bad' = $$bad in
      if  numElements $$input > $$o then let !c = unsafeAt $$input $$o in if $$p c then $$(good [|| $$o + 1 ||] [|| c ||]) else bad'
      else bad'
  ||]

instance GEq ΣVar where
  geq (ΣVar u) (ΣVar v)
    | u == v    = Just (coerce Refl)
    | otherwise = Nothing

instance GCompare ΣVar where
  gcompare (ΣVar u) (ΣVar v) = case compare u v of
    LT -> coerce GLT
    EQ -> coerce GEQ
    GT -> coerce GGT

makeΣ :: [State] -> (DMap ΣVar (QSTRef s) -> QΣ s -> QST s r) -> QST s r
makeΣ ps = makeΣ' ps (DMap.empty) [|| return () ||] [|| return () ||] [|| const (return ()) ||]
  where
    makeΣ' :: [State] -> DMap ΣVar (QSTRef s) -> QST s () -> QST s () -> TExpQ (D -> ST s ()) -> (DMap ΣVar (QSTRef s) -> QΣ s -> QST s r) -> QST s r
    makeΣ' [] m save restore rollback k = [|| let !σs = Σ $$save $$restore (\n -> if n == 0 then return () else $$rollback n) in $$(k m [|| σs ||]) ||]
    makeΣ' (State x qx (ΣVar v):ps) m save restore rollback k = [||
      do σ <- newSTRef ($$qx:::SNil)
         $$(let save' = [|| do modifySTRef' σ ($$qx:::); $$save ||]
                restore' = [|| do modifySTRef' σ (\(_:::xs) -> xs); $$restore ||]
                rollback' = [||\n -> do modifySTRef' σ (sdrop n); $$rollback n ||]
                m' = DMap.insert (ΣVar v) (QSTRef [|| σ ||]) m
            in makeΣ' ps m' save' restore' rollback' k)
      ||]

modifyΣ :: STRef s (SList a) -> (a -> a) -> ST s ()
modifyΣ σ f =
  do (x:::xs) <- readSTRef σ
     writeSTRef σ ((f $! x) ::: xs)

writeΣ :: STRef s (SList a) -> a -> ST s ()
writeΣ σ = modifyΣ σ . const

readΣ :: STRef s (SList a) -> ST s a
readΣ σ =
  do (x:::_) <- readSTRef σ
     return $! x

pokeΣ :: STRef s (SList a) -> a -> ST s a
pokeΣ σ y =
  do (x:::xs) <- readSTRef σ
     writeSTRef σ (y:::xs)
     return $! x

sdrop :: Int -> SList a -> SList a
sdrop 0 xs = xs
sdrop n (_ ::: xs) = sdrop (n-1) xs

data GenMVar a = forall xs ks. GenMVar (MVar xs ks a)
instance Ord (GenMVar a) where compare (GenMVar (MVar u)) (GenMVar (MVar v)) = compare u v
instance Eq (GenMVar a) where (GenMVar (MVar u)) == (GenMVar (MVar v)) = u == v

data GenEval s a = forall xs ks. GenEval (TExpQ (Input -> X xs -> K s ks a -> O -> H s a -> CIdx -> C s -> Σ s -> D -> ST s (Maybe a)))
type FixMap s a = Map (GenMVar a) (GenEval s a)
data Ctx s a = Ctx {μ :: FixMap s a, σm :: DMap ΣVar (QSTRef s), constCount :: Int}

addConstCount :: Int -> Ctx s a -> Ctx s a
addConstCount x ctx = ctx {constCount = constCount ctx + x}

skipBounds :: Ctx s a -> Bool
skipBounds ctx = constCount ctx > 0

eval :: TExpQ String -> (M '[] '[] a, [State]) -> QST s (Maybe a)
eval input (!m, vss) = [||
  do xs <- makeX
     ks <- makeK
     hs <- makeH
     !(cidx, cs) <- makeC
     let input' = $$(toArray input) :: Input
     $$(makeΣ vss (\σm σs -> runReader (eval' m (Γ [||input'||] [||xs||] [||ks||] [||0||] [||hs||] [||cidx||] [||cs||] σs [||0||])) (Ctx Map.empty σm 0)))
  ||]
  where
    toArray :: TExpQ String -> QInput
    toArray input = [|| listArray (0, length $$input-1) $$input ||]

{-# INLINE setupHandlerΓ #-}
setupHandlerΓ :: Γ s xs ks a -> TExpQ (O# -> H s a -> CIdx# -> C s -> D# -> ST s (Maybe a)) ->
                                (QH s a -> QCIdx -> QC s -> QST s (Maybe a)) -> QST s (Maybe a)
setupHandlerΓ γ !h !k = setupHandler (hs γ) (cidx γ) (cs γ) (o γ) h k

{-# INLINE setupHandler #-}
setupHandler :: QH s a -> QCIdx -> QC s -> QO -> TExpQ (O# -> H s a -> CIdx# -> C s -> D# -> ST s (Maybe a)) ->
                                                 (QH s a -> QCIdx -> QC s -> QST s (Maybe a)) -> QST s (Maybe a)
setupHandler !hs !cidx !cs !o !h !k = [||
  do !(cidx', cs') <- pushC $$o $$cidx $$cs
     $$(k [|| pushH $$h $$hs ||] [|| cidx' ||] [|| cs' ||])
  ||]

raiseΓ :: Γ s xs ks a -> QST s (Maybe a)
raiseΓ γ = [|| raise $$(hs γ) $$(cidx γ) $$(cs γ) $$(o γ) $$(d γ) ||]

{-# INLINE raise #-}
raise :: H s a -> CIdx -> C s -> O -> D -> ST s (Maybe a)
raise (H SNil) !_ !_ !_ !_                           = return Nothing
raise (H (h:::hs')) !(I# cidx) !cs !(I# o) !(I# d)   = h o (H hs') cidx cs d

evalHalt :: Γ s xs ks a -> Reader (Ctx s a) (QST s (Maybe a))
evalHalt γ = return [|| case $$(xs γ) of HCons x _ -> return (Just (bug x)) ||]

evalRet :: Γ s (b ': xs) ((b ': xs) ': ks) a -> Reader (Ctx s a) (QST s (Maybe a))
evalRet γ = return [|| do restore $$(σs γ); $$(resume γ) ||]

fix :: (a -> a) -> a
fix f = let x = f x in x

bug :: a -> b
bug = coerce

evalCall :: M xs ((b ': xs) ': ks) a -> MVar xs ((b ': xs) ': ks) a -> M (b ': xs) ks a
         -> Γ s xs ks a -> Reader (Ctx s a) (QST s (Maybe a))
evalCall m v k γ@(Γ input !xs ks o hs cidx cs σs d) =
  do ctx <- ask
     return [|| fix (\r input xs ks o hs cidx cs σs d ->
       do save σs
          $$(let μ' = Map.insert (GenMVar v) (GenEval [||r||]) (μ ctx)
             in runReader (eval' m (Γ [||input||] [|| bug xs ||] [|| bug ks ||] [||o||] [||hs||] [||cidx||] [||cs||] [||σs||] [||d||])) (ctx {μ = μ'})
           )) $$input $$xs $$(suspend k ctx ks) $$o $$hs $$cidx $$cs $$σs ($$d + 1) ||]

evalMuCall :: MVar xs ((b ': xs) ': ks) a -> M (b ': xs) ks a -> Γ s xs ks a -> Reader (Ctx s a) (QST s (Maybe a))
evalMuCall v k γ@(Γ input !xs ks o hs cidx cs σs d) =
  do ctx <- ask
     case (μ ctx) Map.! (GenMVar v) of
       GenEval m -> return [|| $$(coerce m) $$input $$xs $$(suspend k ctx ks) $$o $$hs $$cidx $$cs $$σs ($$d + 1)||]

evalPush :: WQ x -> M (x ': xs) ks a -> Γ s xs ks a -> Reader (Ctx s a) (QST s (Maybe a))
evalPush x k γ = eval' k (γ {xs = [|| pushX $$(_code x) $$(bug (xs γ)) ||]})

evalPop :: M xs ks a -> Γ s (x ': xs) ks a -> Reader (Ctx s a) (QST s (Maybe a))
evalPop k γ = eval' k (γ {xs = [|| popX_ $$(bug (xs γ)) ||]})

evalLift2 :: WQ (x -> y -> z) -> M (z ': xs) ks a -> Γ s (y ': x ': xs) ks a -> Reader (Ctx s a) (QST s (Maybe a))
evalLift2 f k γ = eval' k (γ {xs = [|| let !(y, xs') = popX $$(bug (xs γ)); !(x, xs'') = popX xs' in pushX ($$(_code f) x y) xs'' ||]})

evalSat :: WQ (Char -> Bool) -> M (Char ': xs) ks a -> Γ s xs ks a -> Reader (Ctx s a) (QST s (Maybe a))
evalSat p k γ =
  do ctx <- ask
     return (nextSafe (skipBounds ctx) (input γ) (o γ) (_code p) (\o c -> runReader (eval' k (γ {xs = [|| pushX $$c $$(bug (xs γ)) ||], o = o})) ctx) (raiseΓ γ))

evalEmpt :: Γ s xs ks a -> Reader (Ctx s a) (QST s (Maybe a))
evalEmpt γ = return (raiseΓ γ)

evalCommit :: Bool -> M xs ks a -> Γ s xs ks a -> Reader (Ctx s a) (QST s (Maybe a))
evalCommit exit k γ = local (\ctx -> if exit then addConstCount (-1) ctx else ctx)
                            (eval' k (γ {hs = [|| popH_ $$(hs γ) ||], cidx = [|| popC_ $$(cidx γ) ||]}))

evalHardFork :: M xs ks a -> M xs ks a -> Γ s xs ks a -> Reader (Ctx s a) (QST s (Maybe a))
evalHardFork p q γ =
  do ctx <- ask
     let handler = [||\o hs cidx cs d' ->
           do (c, cidx') <- popC (I# cidx) cs
              if c == (I# o) then do rollback $$(σs γ) ((I# d') - $$(d γ))
                                     $$(runReader (eval' q (γ {o = [||I# o||], hs = [||hs||], cidx = [||cidx'||], cs = [||cs||]})) ctx)
              else raise hs cidx' cs (I# o) (I# d')
           ||]
     return (setupHandlerΓ γ handler (\hs cidx cs -> runReader (eval' p (γ {hs = hs, cidx = cidx, cs = cs})) ctx))

evalSoftFork :: Maybe Int -> M xs ks a -> M xs ks a -> Γ s xs ks a -> Reader (Ctx s a) (QST s (Maybe a))
evalSoftFork constantInput p q γ =
  do ctx <- ask
     let handler = [||\_ hs cidx cs d' ->
           do !(o, cidx') <- popC (I# cidx) cs
              rollback $$(σs γ) ((I# d') - $$(d γ))
              $$(runReader (eval' q (γ {o = [||o||], hs = [||hs||], cidx = [||cidx'||], cs = [||cs||]})) ctx)
           ||]
     return (setupHandlerΓ γ handler (\hs cidx cs ->
       case constantInput of
         Nothing -> runReader (eval' p (γ {hs = hs, cidx = cidx, cs = cs})) ctx
         Just _ | skipBounds ctx -> runReader (eval' p (γ {hs = hs, cidx = cidx, cs = cs})) (addConstCount 1 ctx)
         Just n -> [||
             if numElements $$(input γ) > (n + $$(o γ) - 1) then $$(runReader (eval' p (γ {hs = hs, cidx = cidx, cs = cs})) (addConstCount 1 ctx))
             else $$(raiseΓ (γ {hs = hs, cidx = cidx, cs = cs}))
           ||]
       ))

evalAttempt :: Maybe Int -> M xs ks a -> Γ s xs ks a -> Reader (Ctx s a) (QST s (Maybe a))
evalAttempt constantInput k γ =
  do ctx <- ask
     let handler = [||\(_ :: O#) hs cidx cs d' ->
           do !(o, cidx') <- popC (I# cidx) cs
              raise hs cidx' cs o (I# d')
           ||]
     return (setupHandlerΓ γ handler (\hs cidx cs ->
       case constantInput of
         Nothing -> runReader (eval' k (γ {hs = hs, cidx = cidx, cs = cs})) ctx
         Just _ | skipBounds ctx -> runReader (eval' k (γ {hs = hs, cidx = cidx, cs = cs})) (addConstCount 1 ctx)
         Just n -> [||
             if numElements $$(input γ) > (n + $$(o γ) - 1) then $$(runReader (eval' k (γ {hs = hs, cidx = cidx, cs = cs})) (addConstCount 1 ctx))
             else $$(raiseΓ (γ {hs = hs, cidx = cidx, cs = cs}))
           ||]
       ))


evalLook :: M xs ks a -> Γ s xs ks a -> Reader (Ctx s a) (QST s (Maybe a))
evalLook k γ =
  do ctx <- ask
     let handler = [||\o hs cidx cs d' -> raise hs (popC_ (I# cidx)) cs (I# o) (I# d')||]
     return (setupHandlerΓ γ handler (\hs cidx cs -> runReader (eval' k (γ {hs = hs, cidx = cidx, cs = cs})) ctx))

evalNegLook :: M xs ks a -> M xs ks a -> Γ s xs ks a -> Reader (Ctx s a) (QST s (Maybe a))
evalNegLook m k γ =
  do ctx <- ask
     let handler = [||\_ hs cidx cs d' ->
           do (o, cidx') <- popC (I# cidx) cs
              rollback $$(σs γ) ((I# d') - $$(d γ))
              $$(runReader (eval' k (γ {o = [||o||], hs = [||hs||], cidx = [||cidx'||], cs = [||cs||]})) ctx)
           ||]
     return (setupHandlerΓ γ handler (\hs cidx cs -> runReader (eval' m (γ {hs = hs, cidx = cidx, cs = cs})) ctx))

evalRestore :: M xs ks a -> Γ s xs ks a -> Reader (Ctx s a) (QST s (Maybe a))
evalRestore k γ =
  do ctx <- ask
     return [||
       do (o, cidx') <- popC $$(cidx γ) $$(cs γ)
          $$(runReader (eval' k (γ {o = [||o||], hs = [|| popH_ $$(hs γ) ||], cidx = [||cidx'||]})) ctx)
       ||]

evalCase :: M (x ': xs) ks a -> M (y ': xs) ks a -> Γ s (Either x y ': xs) ks a -> Reader (Ctx s a) (QST s (Maybe a))
evalCase m k γ =
  do ctx <- ask
     return [||
         let !(e, xs') = popX $$(bug (xs γ))
         in case e of
           Right y  -> $$(runReader (eval' k (γ {xs = [||pushX y xs'||]})) ctx)
           Left x -> $$(runReader (eval' m (γ {xs = [||pushX x xs'||]})) ctx)
       ||]

evalChoices :: forall x xs ks a s. [WQ (x -> Bool)] -> [M xs ks a] -> Γ s (x ': xs) ks a -> Reader (Ctx s a) (QST s (Maybe a))
evalChoices fs ks γ = do ctx <- ask; return [|| let (x, xs') = popX $$(bug (xs γ)) in $$(runReader (go [||x||] fs ks (γ {xs = [||xs'||]})) ctx) ||]
  where
    go :: TExpQ x -> [WQ (x -> Bool)] -> [M xs ks a] -> Γ s xs ks a -> Reader (Ctx s a) (QST s (Maybe a))
    go _ [] [] γ = return (raiseΓ γ)
    go x (f:fs) (k:ks) γ =
      do ctx <- ask
         return [||
             if $$(_code f) $$x then $$(runReader (eval' k γ) ctx)
             else $$(runReader (go x fs ks γ) ctx)
           ||]


evalChainIter :: ΣVar x -> MVar xs ks a -> Γ s ((x -> x) ': xs) ks a -> Reader (Ctx s a) (QST s (Maybe a))
evalChainIter u v γ@(Γ input !xs ks o hs cidx cs σs d) =
  do ctx <- ask
     let !(QSTRef σ) = (σm ctx) DMap.! u
     case (μ ctx) Map.! (GenMVar v) of
       GenEval k -> return [||
         do let !(g, xs') = popX $$(bug xs)
            modifyΣ $$σ g
            pokeC $$o $$cidx $$cs
            $$(coerce k) $$input xs' $$ks $$o $$hs $$cidx $$cs $$σs $$d
         ||]

{-evalChainPreInit :: ΣVar (x -> x) -> M xs ks a -> MVar xs ks a -> M ((x -> x) ': xs) ks a
                 -> Γ s xs ks a -> Reader (Ctx s a) (QST s (Maybe a))
evalChainPreInit u l v k γ@(Γ input !xs ks o _ _ _ σs d) =
  do ctx <- ask
     let !(QSTRef σ) = (σm ctx) DMap.! u
     let handler = [||\o hs cidx cs d' ->
          do rollback $$σs ((I# d') - $$d)
             (c, cidx') <- popC (I# cidx) cs
             if c == (I# o) then do f <- pokeΣ $$σ id
                                    $$(runReader (eval' k (γ {xs = [|| pushX f $$(bug xs) ||],
                                                              o = [||I# o||],
                                                              hs = [||hs||],
                                                              cidx = [||cidx'||],
                                                              cs = [||cs||]})) ctx)
             else do writeΣ $$σ id; raise hs cidx' cs (I# o) $$d
          ||]
     return (setupHandlerΓ γ handler (\hs cidx cs -> [||
       -- NOTE: Only the offset and the cs array can change between interations of a chainPre
       fix (\r o cs ->
         $$(let μ' = Map.insert (GenMVar v) (GenEval [|| \_ _ _ o _ _ cs _ _ -> r o cs ||]) (μ ctx)
            in runReader (eval' l (Γ input (bug xs) (bug ks) [||o||] hs cidx [||cs||] σs d)) (ctx {μ = μ'})))
       $$o $$cs||]))-}

evalChainInit :: WQ x -> ΣVar x -> M xs ks a -> MVar xs ks a -> M (x ': xs) ks a
                  -> Γ s (x ': xs) ks a -> Reader (Ctx s a) (QST s (Maybe a))
evalChainInit deflt u l v k γ@(Γ input !xs ks o _ _ _ σs d) =
  do ctx <- ask
     let !(QSTRef σ) = (σm ctx) DMap.! u
     let xs' = [|| popX $$(bug xs) ||]
     let handler = [||\o hs cidx cs d' ->
          do rollback $$σs ((I# d') - $$d)
             (c, cidx') <- popC (I# cidx) cs
             if c == (I# o) then do y <- pokeΣ $$σ $$(_code deflt)
                                    $$(runReader (eval' k (γ {xs = [|| pushX y (snd $$xs') ||],
                                                              o = [||I# o||],
                                                              hs = [||hs||],
                                                              cidx = [||cidx'||],
                                                              cs = [||cs||]})) ctx)
             else do writeΣ $$σ $$(_code deflt); raise hs cidx' cs (I# o) $$d
          ||]
     return (setupHandlerΓ γ handler (\hs cidx cs -> [||
       -- NOTE: Only the offset and the cs array can change between interations of a chainPre
       do writeΣ $$σ (fst $$xs')
          fix (\r o cs ->
            $$(let μ' = Map.insert (GenMVar v) (GenEval [|| \_ _ _ o _ _ cs _ _ -> r o cs ||]) (μ ctx)
               in runReader (eval' l (Γ input [||snd $$xs'||] (bug ks) [||o||] hs cidx [||cs||] σs d)) (ctx {μ = μ'})))
            $$o $$cs||]))

eval' :: M xs ks a -> Γ s xs ks a -> Reader (Ctx s a) (QST s (Maybe a))
eval' Halt γ                  = trace "HALT" $ evalHalt γ
eval' Ret γ                   = trace "RET" $ evalRet γ
eval' (Call m v k) γ          = trace "CALL" $ evalCall m v k γ
eval' (MuCall v k) γ          = trace "MUCALL" $ evalMuCall v k γ
eval' (Push x k) γ            = trace "PUSH" $ evalPush x k γ
eval' (Pop k) γ               = trace "POP" $ evalPop k γ
eval' (Lift2 f k) γ           = trace "LIFT2" $ evalLift2 f k γ
eval' (Sat p k) γ             = trace "SAT" $ evalSat p k γ
eval' Empt γ                  = trace "EMPT" $ evalEmpt γ
eval' (Commit exit k) γ       = trace "COMMIT" $ evalCommit exit k γ
eval' (HardFork p q) γ        = trace "HARDFORK" $ evalHardFork p q γ
eval' (SoftFork n p q) γ      = trace "SOFTFORK" $ evalSoftFork n p q γ
eval' (Attempt n k) γ         = trace "ATTEMPT" $ evalAttempt n k γ
eval' (Look k) γ              = trace "LOOK" $ evalLook k γ
eval' (NegLook m k) γ         = trace "NEGLOOK" $ evalNegLook m k γ
eval' (Restore k) γ           = trace "RESTORE" $ evalRestore k γ
eval' (Case m k) γ            = trace "CASE" $ evalCase m k γ
eval' (Choices fs ks) γ       = trace "CHOICES" $ evalChoices fs ks γ
eval' (ChainIter σ v) γ       = trace "CHAINITER" $ evalChainIter σ v γ
eval' (ChainInit x σ l v k) γ = trace "CHAININIT" $ evalChainInit x σ l v k γ

runParser :: Parsley.Parser a -> TExpQ (String -> Maybe a)
runParser p = --runST (compile (preprocess p) >>= eval input)
  [||\input -> runST $$(eval [|| input ||] (compile (preprocess p)))||]

{-data CompiledParser a = Compiled (forall s. M '[] '[] a)

mkParser :: Parser a -> CompiledParser a
mkParser p = Compiled (runST (slightyUnsafeLeak (compile (preprocess p))))
  where
    slightyUnsafeLeak :: (forall s. ST s (M s '[] '[] a)) -> (forall s. ST s (M s' '[] '[] a))
    slightyUnsafeLeak = unsafeCoerce

runCompiledParser :: CompiledParser a -> String -> Maybe a
runCompiledParser (Compiled p) input = runST (eval input p)-}

showM :: Parser a -> String
showM p = show (fst (compile (preprocess p)))
