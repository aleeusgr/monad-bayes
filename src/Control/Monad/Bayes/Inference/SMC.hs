{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE RecordWildCards #-}

-- |
-- Module      : Control.Monad.Bayes.Inference.SMC
-- Description : SequentialT Monte Carlo (SMC)
-- Copyright   : (c) Adam Scibior, 2015-2020
-- License     : MIT
-- Maintainer  : leonhard.markert@tweag.io
-- Stability   : experimental
-- Portability : GHC
--
-- SequentialT Monte Carlo (SMC) sampling.
--
-- Arnaud Doucet and Adam M. Johansen. 2011. A tutorial on particle filtering and smoothing: fifteen years later. In /The Oxford Handbook of Nonlinear Filtering/, Dan Crisan and Boris Rozovskii (Eds.). Oxford University Press, Chapter 8.
module Control.Monad.Bayes.Inference.SMC
  ( smc,
    smcPush,
    SMCConfig (..),
  )
where

import Control.Monad.Bayes.Class (MonadInfer, MonadSample)
import Control.Monad.Bayes.PopulationT
  ( PopulationT,
    pushEvidence,
    withParticles,
  )
import Control.Monad.Bayes.SequentialT as Seq
  ( SequentialT,
    hoistFirst,
    sequentially,
  )

data SMCConfig m = SMCConfig
  { resampler :: forall x. PopulationT m x -> PopulationT m x,
    numSteps :: Int,
    numParticles :: Int
  }

-- | SequentialT importance resampling.
-- Basically an SMC template that takes a custom resampler.
smc ::
  MonadSample m =>
  SMCConfig m ->
  SequentialT (PopulationT m) a ->
  PopulationT m a
smc SMCConfig {..} = sequentially resampler numSteps . Seq.hoistFirst (withParticles numParticles)

-- | SequentialT Monte Carlo with multinomial resampling at each timestep.
-- Weights are normalized at each timestep and the total weight is pushed
-- as a score into the transformed monad.
smcPush ::
  MonadInfer m => SMCConfig m -> SequentialT (PopulationT m) a -> PopulationT m a
smcPush config = smc config {resampler = (pushEvidence . resampler config)}
