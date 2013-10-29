--  Copyright (C) 2006-2008 Angelos Charalambidis <a.charalambidis@di.uoa.gr>
--
--  This program is free software; you can redistribute it and/or modify
--  it under the terms of the GNU General Public License as published by
--  the Free Software Foundation; either version 2, or (at your option)
--  any later version.
--
--  This program is distributed in the hope that it will be useful,
--  but WITHOUT ANY WARRANTY; without even the implied warranty of
--  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
--  GNU General Public License for more details.
--
--  You should have received a copy of the GNU General Public License
--  along with this program; see the file COPYING.  If not, write to
--  the Free Software Foundation, Inc., 51 Franklin Street, Fifth Floor,
--  Boston, MA 02110-1301, USA.

module BasicPretty (
        module Pretty
    ) where


import Pretty


import Loc (Loc(..), LocSpan(..))
import Lang (Sym(..))
import Types (Typed(..), TyVar(..), MonoTypeV(..), GrdType(..), TyEnv(..), TySig(..), tyvars)
import Data.List (nub)


instance Pretty Sym where
    ppr (Sym s) = ppr s
    ppr AnonSym = text "_"

instance Pretty a => Pretty (Typed a) where
    ppr (T a ty) = ppr a -- <> dcolon <> ppr ty

instance Pretty GrdType where
    ppr TyBool = text "o"
    ppr TyAll  = text "i"

instance Pretty TyVar where
    ppr (Tv i _) = int i

instance (Eq a, Pretty a) => Pretty (MonoTypeV a) where
    ppr t = pprPrec 1 f t
        where f = tvmap [t]

-- pprPrec p f (TyTup tl)     = parens $ sep (punctuate comma (map (pprPrec 1 f) tl))
pprPrec p f (TyGrd c)      = ppr c
pprPrec p f (TyVar v)      = f v
pprPrec p f ty@(TyFun t t') =  if (p == 0) then
                                   parens (sep [ pprPrec 0 f t , arrow <+> pprPrec p f t' ])
                               else
                                   sep [ pprPrec 0 f t , arrow <+> pprPrec p f t' ]

tynames = letters ++ [ x++(show i) | x <- letters, i <- [1..] ]
    where letters = [ "a", "b", "c", "d", "e", "f" ]

tvmap tys v = 
    let tvs = nub $ concatMap tyvars tys
        fl  = zip tvs tynames
    in case lookup v fl of
            Nothing -> ppr v
            Just n  -> text n


instance Pretty a => Pretty (TySig a) where
    ppr (a,t) = sep [ ppr a, dcolon <+> ppr t]

instance Pretty a => Pretty (TyEnv a) where
    ppr ts = vcat $ map ppr ts

