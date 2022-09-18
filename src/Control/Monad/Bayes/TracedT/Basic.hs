{-# LANGUAGE RankNTypes #-}

-- |
-- Module      : Control.Monad.Bayes.TracedT.Basic
-- Description : Distributions on full execution traces of full programs
-- Copyright   : (c) Adam Scibior, 2015-2020
-- License     : MIT
-- Maintainer  : leonhard.markert@tweag.io
-- Stability   : experimental
-- Portability : GHC
module Control.Monad.Bayes.TracedT.Basic
  ( TracedT,
    hoist,
    marginal,
    mhStep,
    mh,
  )
where

import Control.Applicative (liftA2)
import Control.Monad.Bayes.Class
  ( MonadCond (..),
    MonadInfer,
    MonadSample (random),
  )
import Control.Monad.Bayes.Density.Free (Density)
import Control.Monad.Bayes.TracedT.Common
  ( Trace (..),
    bind,
    mhTrans',
    scored,
    singleton,
  )
import Control.Monad.Bayes.Weighted (Weighted)
import Data.Functor.Identity (Identity)
import Data.List.NonEmpty as NE (NonEmpty ((:|)), toList)

-- | Tracing monad that records random choices made in the program.
data TracedT m a = TracedT
  { -- | Run the program with a modified trace.
    model :: Weighted (Density Identity) a,
    -- | Record trace and output.
    traceDist :: m (Trace a)
  }

instance Monad m => Functor (TracedT m) where
  fmap f (TracedT m d) = TracedT (fmap f m) (fmap (fmap f) d)

instance Monad m => Applicative (TracedT m) where
  pure x = TracedT (pure x) (pure (pure x))
  (TracedT mf df) <*> (TracedT mx dx) = TracedT (mf <*> mx) (liftA2 (<*>) df dx)

instance Monad m => Monad (TracedT m) where
  (TracedT mx dx) >>= f = TracedT my dy
    where
      my = mx >>= model . f
      dy = dx `bind` (traceDist . f)

instance MonadSample m => MonadSample (TracedT m) where
  random = TracedT random (fmap singleton random)

instance MonadCond m => MonadCond (TracedT m) where
  score w = TracedT (score w) (score w >> pure (scored w))

instance MonadInfer m => MonadInfer (TracedT m)

hoist :: (forall x. m x -> m x) -> TracedT m a -> TracedT m a
hoist f (TracedT m d) = TracedT m (f d)

-- | Discard the trace and supporting infrastructure.
marginal :: Monad m => TracedT m a -> m a
marginal (TracedT _ d) = fmap output d

-- | A single step of the Trace Metropolis-Hastings algorithm.
mhStep :: MonadSample m => TracedT m a -> TracedT m a
mhStep (TracedT m d) = TracedT m d'
  where
    d' = d >>= mhTrans' m

-- | Full run of the Trace Metropolis-Hastings algorithm with a specified
-- number of steps.
mh :: MonadSample m => Int -> TracedT m a -> m [a]
mh n (TracedT m d) = fmap (map output . NE.toList) (f n)
  where
    f k
      | k <= 0 = fmap (:| []) d
      | otherwise = do
        (x :| xs) <- f (k - 1)
        y <- mhTrans' m x
        return (y :| x : xs)
