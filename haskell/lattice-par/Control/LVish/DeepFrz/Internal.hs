-- I am an UNSAFE module.

{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE DefaultSignatures #-}
{-# LANGUAGE EmptyDataDecls #-}

-- | This module is NOT Safe-Haskell, but it must be used to create
-- new LVar types.
module Control.LVish.DeepFrz.Internal
       (
         DeepFrz(..), Frzn, Trvrsbl 
       )
       where

-- | DeepFreezing is type-level (guaranteed O(1) time complexity)
-- operation.  It marks an LVar and its contents (recursively) as
-- frozen.  DeepFreezing is not an action that can be taken directly
-- by the user, however.  Rather it is an optional final-step in a
-- `runPar` invocation.
class DeepFrz a where
  -- | This type function is public.  It maps pre-frozen types to
  -- frozen ones.  It should be idempotent.
  type FrzType a :: *

  -- | Private: not exported to the end user.
  frz :: a -> FrzType a

  -- | While `frz` is not exported, users may opt-in to the `DeepFrz`
  -- class for their datatypes and take advantage of the default instance.
  -- Doing so REQUIRES that `type FrzType a = a`.
  default frz :: a -> a 
  frz a = a 

-- | An uninhabited type that signals an LVar has been frozen.
--   LVars should use this inplace of their `s` parameter.
data Frzn

-- | An uninhabited type that signals an LVar is not only frozen, but
-- it may be traversed in whatever order its internal representation
-- dictates.
data Trvrsbl 
