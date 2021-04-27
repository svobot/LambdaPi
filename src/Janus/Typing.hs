module Janus.Typing
  ( iType0
  ) where

import           Control.Monad.Except           ( throwError )
import           Control.Monad.Reader           ( MonadReader(local)
                                                , ReaderT(runReaderT)
                                                , asks
                                                , unless
                                                , when
                                                )
import           Data.Bifunctor                 ( first )
import           Data.List                      ( find )
import qualified Data.Map.Merge.Strict         as Map
import qualified Data.Map.Strict               as Map
import           Data.Maybe                     ( fromMaybe
                                                , mapMaybe
                                                )
import           Janus.Printer
import           Janus.Semiring
import           Janus.Types

type Usage = Map.Map Name ZeroOneMany
data TypingConfig = TypingConfig
  { cfgGlobalContext :: Context
  , cfgBoundLocals   :: TypeEnv
  }
type Judgment = ReaderT TypingConfig Result

iType0 :: Context -> ZeroOneMany -> ITerm -> Result Type
iType0 g r t = do
  (qs, tp) <- first (Map.map (r .*.))
    <$> runReaderT (iType (relevance r) t) (TypingConfig g [])
  mapM_ (throwError . MultiplicityError Nothing) $ checkMultiplicity (snd g) qs
  return tp

with :: Binding Name ZeroOneMany Type -> TypingConfig -> TypingConfig
with b cfg = cfg { cfgBoundLocals = b : cfgBoundLocals cfg }

-- | Judges in typing context extended with a local variable.
withLocalVar
  :: String -> Binding Name ZeroOneMany Type -> Judgment Usage -> Judgment Usage
withLocalVar loc v jud = local (with v) $ jud >>= checkVar (bndName v)
 where
  -- If usage of a local variable doesn't match available resources,
  -- judgment fails.
  checkVar :: Name -> Usage -> Judgment Usage
  checkVar n qs = do
    env <- asks typeEnv
    let (q, qs') = splitVar n qs
    mapM_ (throwError . MultiplicityError (Just loc))
          (checkMultiplicity env $ Map.singleton n q)
    return qs'

  splitVar = (first (fromMaybe zero) .) . Map.alterF (, Nothing)

-- | Makes local variable with fresh name
newLocalVar :: a -> b -> Judgment (Binding Name a b)
newLocalVar r ty = do
  i <- asks $ length . cfgBoundLocals
  return $ Binding (Local i) r ty

typeEnv :: TypingConfig -> TypeEnv
typeEnv (TypingConfig (_, ts) bs) = bs ++ ts

evalInEnv :: CTerm -> Judgment Value
evalInEnv t = asks (cEval t . (, []) . fst . cfgGlobalContext)

-- | Infer the type and count the resource usage of the term.
iType :: Relevance -> ITerm -> Judgment (Usage, Type)
iType r (Ann e tyt) = do
  cTypeErased tyt VUniverse
  ty <- evalInEnv tyt
  qs <- cType r e ty
  return (qs, ty)
iType r (Free x) = do
  env <- asks typeEnv
  case find ((== x) . bndName) env of
    Just (Binding _ _ ty) -> return (Map.singleton x $ extend r, ty)
    Nothing               -> throwError $ UnknownVarError x
iType r (e1 :$: e2) = do
  (qs1, si) <- iType r e1
  case si of
    VPi p ty ty' -> do
      qs <- case p .*. extend r of
        Zero -> do
          cTypeErased e2 ty
          return qs1
        pr -> do
          qs2 <- cType Present e2 ty
          return $ Map.unionWith (.+.) qs1 (Map.map (pr .*.) qs2)
      (qs, ) . ty' <$> evalInEnv e2
    ty -> throwError $ InferenceError "_ -> _" ty (e1 :$: e2)
iType r (MPairElim l i t) = do
  (qs1, lTy) <- iType r l
  case lTy of
    zTy@(VMPairType p xTy yTy) -> do
      z <- newLocalVar zero zTy
      local (with z) (cTypeErased (cSubst 0 (Free $ bndName z) t) VUniverse)
      let r' = extend r
      x  <- newLocalVar (p .*. r') xTy
      qs <- withLocalVar
        "First element of the pair elimination"
        x
        (do
          y <- newLocalVar r' (yTy . vfree $ bndName x)
          withLocalVar "Second element of the pair elimination" y $ do
            txy <- evalInEnv
              (cSubst 0 (Ann (MPair (ifn x) (ifn y)) (quote0 zTy)) t)
            qs2 <- cTypeSubst x y txy
            return (Map.unionWith (.+.) qs1 qs2)
        )
      (qs, ) <$> evalInEnv (cSubst 0 l t)
    ty -> throwError
      $ InferenceError ("_" <+> mult "*" <+> "_") ty (MPairElim l i t)
 where
  ifn = Inf . Free . bndName
  cTypeSubst x y txy =
    cType r (cSubst 1 (Free $ bndName x) . cSubst 0 (Free $ bndName y) $ i) txy
iType r (MUnitElim l i t) = do
  (qs1, lTy) <- iType r l
  case lTy of
    xTy@VMUnitType -> do
      x <- newLocalVar zero xTy
      local (with x) (cTypeErased (cSubst 0 (Free $ bndName x) t) VUniverse)
      tu  <- evalInEnv (cSubst 0 (Ann MUnit MUnitType) t)
      qs2 <- cType r i tu
      let qs = Map.unionWith (.+.) qs1 qs2
      (qs, ) <$> evalInEnv (cSubst 0 l t)
    ty -> throwError $ InferenceError (pretty MUnitType) ty (MUnitElim l i t)
iType r (Fst i) = do
  (qs, ty) <- iType r i
  case ty of
    (VAPairType s _) -> return (qs, s)
    _ -> throwError $ InferenceError ("_" <+> add "&" <+> "_") ty (Fst i)
iType r (Snd i) = do
  (qs, ty) <- iType r i
  case ty of
    (VAPairType _ t) -> (qs, ) . t <$> evalInEnv (Inf $ Fst i)
    _ -> throwError $ InferenceError ("_" <+> add "&" <+> "_") ty (Snd i)
iType _ i@(Bound _) = error $ "internal: Trying to infer type of " <> show i

-- | Check the type and count the resource usage of the term.
cType :: Relevance -> CTerm -> Type -> Judgment Usage
cType r (Inf e) v = do
  (qs, v') <- iType r e
  when (quote0 v /= quote0 v') (throwError $ InferenceError (pretty v) v' e)
  return qs
cType r (Lam e) (VPi p ty ty') = do
  x <- newLocalVar (p .*. extend r) ty
  withLocalVar "Lambda abstraction" x
    $ cType r (cSubst 0 (Free $ bndName x) e) (ty' . vfree $ bndName x)
cType r (MPair e1 e2) (VMPairType p ty ty') = do
  case p .*. extend r of
    Zero -> do
      cTypeErased e1 ty
      rest
    pr -> do
      qs1 <- cType Present e1 ty
      qs2 <- rest
      return $ Map.unionWith (.+.) qs2 (Map.map (pr .*.) qs1)
  where rest = evalInEnv e1 >>= (cType r e2 . ty')
cType r (APair e1 e2) (VAPairType ty ty') = do
  qs1 <- cType r e1 ty
  qs2 <- evalInEnv e1 >>= (cType r e2 . ty')
  -- For every resource that is used anywhere in the pair, take the least upper
  -- bound of the resource usages in both elements of the pair. The element that
  -- is missing a usage of a resource is considered to use it zero-times.
  return $ Map.merge (Map.mapMissing (const $ lub zero))
                     (Map.mapMissing (const $ lub zero))
                     (Map.zipWithMatched (const lub))
                     qs1
                     qs2
cType _ MUnit                 VMUnitType = return Map.empty
cType _ AUnit                 VAUnitType = return Map.empty
cType r t@(Pi        _ t1 t2) VUniverse  = cDepType "Pi type" r t t1 t2
cType r t@(MPairType _ t1 t2) VUniverse  = cDepType "Tensor type" r t t1 t2
cType r t@(APairType t1 t2  ) VUniverse  = cDepType "With type" r t t1 t2
cType r t@Universe            VUniverse  = cAtomType r t
cType r t@MUnitType           VUniverse  = cAtomType r t
cType r t@AUnitType           VUniverse  = cAtomType r t
cType _ val                   ty         = throwError $ CheckError ty val

-- | Check the type of dependent types.
--
-- Generic typing rule that check terms containing one of: dependent function
-- type, dependent multiplicative pair type, or dependent additive pair type.
cDepType :: String -> Relevance -> CTerm -> CTerm -> CTerm -> Judgment Usage
cDepType loc r t tyt tyt' = do
  when (r /= Erased) (throwError . ErasureError t $ extend r)
  cTypeErased tyt VUniverse
  x <- evalInEnv tyt >>= newLocalVar zero
  withLocalVar loc x $ cType r (cSubst 0 (Free $ bndName x) tyt') VUniverse

-- | Check the type of atomic types.
cAtomType :: Relevance -> CTerm -> Judgment Usage
cAtomType r t = case r of
  Erased  -> return Map.empty
  Present -> throwError . ErasureError t $ extend r

checkMultiplicity
  :: TypeEnv -> Usage -> Maybe [(Name, Type, ZeroOneMany, ZeroOneMany)]
checkMultiplicity env = toMaybe . mapMaybe notEnough . Map.toList
 where
  notEnough (n, q) = case find ((== n) . bndName) env of
    Just b | q `fitsIn` bndUsage b -> Nothing
           | otherwise             -> Just (n, bndType b, q, bndUsage b)
    Nothing ->
      error $ "internal: Unknown " <> show n <> " used " <> show q <> "-times"
  toMaybe [] = Nothing
  toMaybe es = Just es

-- | Type-check in erased context.
cTypeErased :: CTerm -> Type -> Judgment ()
cTypeErased c t = do
  errs <- Map.filter (/= zero) <$> cType Erased c t
  -- Having a non-zero usage of a variable in the erased context means that
  -- there is something wrong with the type checking algorithm; throw an error.
  unless
    (Map.null errs)
    (  error
    $  "internal: Variables used in the erased context: \n"
    <> Map.foldrWithKey
         (\k v -> (<> "    " <> show k <> " used " <> show v <> "-times\n"))
         ""
         errs
    )

