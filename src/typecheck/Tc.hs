module Tc (
        module Tc,
        module TcMonad
    ) where

import TcMonad
import Types
import Syntax
import Err
import Loc
import Pretty
import Monad    (zipWithM, zipWithM_, when)
import Control.Monad.Reader (asks)
import Data.Monoid

{-
    Strategy of type checking

    Alternative I.

    1. tc functions just type checks the source without annotate the syntax tree with types.
    2. tc functions just collect Constraints and fail if cannot satisfy constraints.
    3. The main problem is that local bindings does not exist in the global type environment.
       As a result after the type check of a quantified formula (or lambda expression) we have to
       store somewhere the types (or tyvars) of those bindings.

    Alternative II.

    1. tc functions check and if succeed annotate the source with types.
    2. syntax tree is already parametrized with the symbol type, so the new syntax tree must have
       a new symbol type that can hold other info about the symbol such as type and arity.
    3. The annotation of the tree cannot be performed before the type checking completes. Types of
       symbols (and therefore local bindings) are not fixed during the type checking.
       As a result, the real annotation must happen *after* the type checking.

    Ugly thinks
    1. Location information (helps on error messagings but it is not part of the logic of type checking)
    2. Context information (as in 1)
    3. Bindings and annotation (annotation helps next stages but it's checking not annotating)

-}

-- tcSource :: PHpSource HpSymbol -> Tc (HpSource HpSymbol, TypeEnv)
tcSource src = do
    let tysign = map unLoc (tysigs src)
        cls    = clauses src
        sigma  = sig src
        rgds   = rigids sigma
    tv_sym <- mapM initNewTy rgds
    extendEnv tv_sym $ do
    extendEnv tysign $ do
        mapM_ tcForm cls
        let cls' = cls
        ty_env  <- normEnv
        return (src{ clauses = cls' }, ty_env)

-- type checking and inference

-- tcForm :: LHpFormula a -> Tc (LHpFormula b)
tcForm f@(L _ (HpForm b xs ys)) =
    enterContext (CtxtForm f) $ do
    tvs <- mapM (initNewTy.symbolBind) (binds f)
    extendEnv tvs $ do
        mapM_ tcAtom xs
        mapM_ tcAtom ys


-- tcAtom, tcAtom' :: LHpAtom a -> Tc ()
tcAtom a = enterContext (CtxtAtom a) $ tcExpr a tyBool

-- tiExpr :: LHpExpr a -> Tc (MonoType, LHpExpr)
tiExpr e = do
    var_ty <- newTyVar
    tcExpr e var_ty
    return var_ty

-- tcExpr, tcExpr' :: LHpExpr a -> MonoType -> Tc ()

tcExpr e t = enterContext (CtxtExpr e) $ tcExpr' e t

tcExpr' (L _ (HpPar  e)) exp_ty = tcExpr e exp_ty

tcExpr' (L _ (HpAnn e ty)) exp_ty = do
    ann_ty <- instantiate ty
    tcExpr e ann_ty
    unify ann_ty exp_ty

tcExpr' (L _ (HpApp e args)) exp_ty = do
    fun_ty  <- tiExpr e
    args_ty <- mapM tiExpr args
    let tup_ty = case args_ty of
                     [x] -> x
                     tys -> TyTup tys
    (arg_ty, res_ty) <- unifyFun fun_ty
    unify arg_ty tup_ty
    unify res_ty exp_ty

tcExpr' (L _ (HpSym s)) exp_ty = do
    sym_ty <- lookupVar s
    unify sym_ty exp_ty

tcExpr' (L _ (HpTup es)) exp_ty = do
    tys <- mapM tiExpr es
    unify (TyTup tys) exp_ty


tcExpr' (L _ (HpWildcat)) _ = return ()

-- unification

unify :: MonoType -> MonoType -> Tc ()
unify (TyVar v1) t@(TyVar v2)
    | v1 == v2    = return ()
    | otherwise   = unifyVar v1 t

unify (TyVar v) t = unifyVar v t
unify t (TyVar v) = unifyVar v t

unify (TyFun fun1 arg1) (TyFun fun2 arg2) =
    unify fun1 fun2 >> unify arg1 arg2

unify t@(TyTup tys) t'@(TyTup tys')
    | length tys == length tys' = zipWithM_ unify tys tys'
    | otherwise                 = unificationErr t t'
unify t t'
    | t == t'     = return ()
    | otherwise   = unificationErr t t'


unifyFun t = do
    arg_ty <- newTyVar
    res_ty  <- newTyVar
    unify (TyFun arg_ty res_ty) t
    return (arg_ty, res_ty)

unifyVar v t = do
    maybe_ty <- lookupTyVar v
    case maybe_ty of
        Nothing -> varBind v t
        Just t' -> unify t' t

varBind  v1 t@(TyVar v2) = do
    maybe_ty <- lookupTyVar v2
    case maybe_ty of
        Nothing -> addConstraint v1 t
        Just ty -> unify (TyVar v1) ty

varBind v ty = do
    tvs <- getTyVars ty
    if (v `elem` tvs) then occurCheckErr v ty else addConstraint v ty


-- utilities

instantiate :: Type -> Tc MonoType
instantiate t = return t

generalize :: MonoType -> Tc Type
generalize t = return t

-- getTyVars :: MonoType -> Tc [TyVar]
getTyVars (TyVar v) = do
    maybe_ty <- lookupTyVar v
    case maybe_ty of
        Nothing  -> return [v]
        Just ty' -> getTyVars ty' >>= \tvs' -> return $ v:tvs'

getTyVars (TyFun ty1 ty2) = do
    tvs1 <- getTyVars ty1
    tvs2 <- getTyVars ty2
    return (tvs1 `mappend` tvs2)

getTyVars (TyTup tl) = do
    l <- mapM getTyVars tl
    return (mconcat l)

getTyVars (TyCon _) = return mempty


normEnv :: Tc TypeEnv
normEnv = 
    let aux (v,t) = do
            t' <- normType t
            return (v, t')
    in do
        env <- asks tyenv
        mapM aux env

normType (TyFun t1 t2) = do
    t1' <- normType t1
    t2' <- normType t2
    return $ TyFun t1' t2'

normType (TyVar tv) = do
    ty <- lookupTyVar tv
    case ty of
        Just t -> normType t
        Nothing -> return $ TyVar tv

normType (TyTup tl) = do
    tl' <- mapM normType tl
    return $ TyTup tl'

normType t = return t

initNewTy v = do
    ty <- newTyVar >>= generalize
    return (v, ty)

annoSym :: HpSymbol -> Tc TcSymbol
annoSym sym@(Sym s) = do
    ty' <- lookupVar sym
    ty <- normType ty'
    return (TcS s (arity ty) ty)

-- error reporting

unificationErr inf_ty exp_ty = do
        inf_ty' <- normType inf_ty
        exp_ty' <- normType exp_ty
        let desc = hang (text "Could not match types:") 4 
                        (vcat [ text "Inferred:" <+> ppr inf_ty', 
                                text "Expected:" <+> ppr exp_ty' ])
        typeError desc


occurCheckErr tv ty = do
    let desc = text "Could not construct an infinite type:"
    typeError desc
