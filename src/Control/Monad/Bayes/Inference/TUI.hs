{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE ImportQualifiedPost #-}
{-# OPTIONS_GHC -Wno-type-defaults #-}

module Control.Monad.Bayes.Inference.TUI where

import Brick
import Brick qualified as B
import Brick.BChan qualified as B
import Brick.Widgets.Border
import Brick.Widgets.Border.Style
import Brick.Widgets.Center
import Brick.Widgets.ProgressBar qualified as B
import Control.Arrow (Arrow (..))
import Control.Concurrent (forkIO)
import Control.Foldl qualified as Fold
import Control.Monad (void)
import Control.Monad.Bayes.Enumerator (toEmpirical)
import Control.Monad.Bayes.Inference.MCMC
import Control.Monad.Bayes.Sampler.Strict (SamplerIO, sampleIO, toBins)
import Control.Monad.Bayes.TracedT (TracedT)
import Control.Monad.Bayes.TracedT.Common
import Control.Monad.Bayes.Weighted
import Data.List (sort)
import Data.Map qualified as M
import Data.Scientific (FPFormat (Exponent), formatScientific, fromFloatDigits)
import Data.Text qualified as T
import Data.Text.Lazy qualified as TL
import Data.Text.Lazy.IO qualified as TL
import GHC.Float (double2Float)
import Graphics.Vty
import Graphics.Vty qualified as V
import Numeric.Log (Log (ln))
import Pipes (MonadIO (liftIO), runEffect, (>->))
import Pipes qualified as P
import Pipes.Prelude qualified as P
import Text.Pretty.Simple (pShow, pShowNoColor)

data MCMCData a = MCMCData
  { numSteps :: Int,
    numSuccesses :: Int,
    samples :: [a],
    lk :: [Double],
    totalSteps :: Int
  }
  deriving stock (Show)

-- | Brick is a terminal user interface (TUI)
-- which we use to display inference algorithms in progress

-- | draw the brick app
drawUI :: ([a] -> Widget n) -> MCMCData a -> [Widget n]
drawUI handleSamples state = [ui]
  where
    completionBar =
      updateAttrMap
        ( B.mapAttrNames
            [ (doneAttr, B.progressCompleteAttr),
              (toDoAttr, B.progressIncompleteAttr)
            ]
        )
        $ toBar $ fromIntegral $ numSteps state

    likelihoodBar =
      updateAttrMap
        ( B.mapAttrNames
            [ (doneAttr, B.progressCompleteAttr),
              (toDoAttr, B.progressIncompleteAttr)
            ]
        )
        $ B.progressBar
          (Just $ "Mean likelihood for last 1000 samples: " <> take 10 (show (head $ lk state <> [0])))
          (double2Float (Fold.fold Fold.mean $ take 1000 $ lk state) / double2Float (maximum $ 0 : lk state))

    displayStep c = Just $ "Step " <> show c
    numFailures = numSteps state - numSuccesses state
    toBar v = B.progressBar (displayStep v) (v / fromIntegral (totalSteps state))
    displaySuccessesAndFailures =
      withBorderStyle unicode $
        borderWithLabel (str "Successes and failures") $
          center (str (show $ numSuccesses state))
            <+> vBorder
            <+> center (str (show numFailures))
    warning =
      if numSteps state > 1000 && (fromIntegral (numSuccesses state) / fromIntegral (numSteps state)) < 0.1
        then withAttr (attrName "highlight") $ str "Warning: acceptance rate is rather low.\nThis probably means that your proposal isn't good."
        else str ""

    ui =
      (str "Progress: " <+> completionBar)
        <=> (str "Likelihood: " <+> likelihoodBar)
        <=> str "\n"
        <=> displaySuccessesAndFailures
        <=> warning
        <=> handleSamples (samples state)

noVisual :: b -> Widget n
noVisual = const emptyWidget

showEmpirical :: (Show a, Ord a) => [a] -> Widget n
showEmpirical =
  txt
    . T.pack
    . TL.unpack
    . pShow
    . (fmap (second (formatScientific Exponent (Just 3) . fromFloatDigits)))
    . toEmpirical

showVal :: Show a => [a] -> Widget n
showVal = txt . T.pack . (\case [] -> ""; a -> show $ head a)

showHistogram :: [Double] -> Widget n
showHistogram samples =
  let dict = Fold.fold (Fold.foldByKeyMap Fold.sum) (fmap (,1) $ toBins 0.1 $ take 10000 (samples))
      valSum = fromIntegral $ sum $ M.elems dict
      bins = M.keys dict
      ndict = M.map ((/ valSum) . fromIntegral) dict
      makeBar bin dict =
        cropTop 10 $
          pad 0 10 0 0 $
            charFill (fg yellow) '.' 1 (1 * maybe 0 (round . (* 100)) (M.lookup bin dict))
   in withBorderStyle
        unicode
        ( raw $
            horizCat [makeBar bin ndict | bin <- sort bins]
        )

-- | handler for events received by the TUI
appEvent :: s -> B.BrickEvent n1 s -> B.EventM n2 (B.Next s)
appEvent p (B.VtyEvent e) =
  case e of
    V.EvKey (V.KChar 'q') [] -> do
      B.halt p
    _ -> B.continue p
appEvent _ (B.AppEvent d) = B.continue d
appEvent _ _ = error "unknown event"

doneAttr, toDoAttr :: B.AttrName
doneAttr = B.attrName "theBase" <> B.attrName "done"
toDoAttr = B.attrName "theBase" <> B.attrName "remaining"

theMap :: B.AttrMap
theMap =
  B.attrMap
    V.defAttr
    [ (B.attrName "theBase", bg V.brightBlack),
      (doneAttr, V.black `on` V.white),
      (toDoAttr, V.white `on` V.black),
      (attrName "highlight", fg yellow)
    ]

tui :: Show a => Int -> TracedT (Weighted SamplerIO) a -> ([a] -> Widget ()) -> IO ()
tui burnIn distribution visualizer = void do
  eventChan <- B.newBChan 10
  initialVty <- buildVty
  _ <- forkIO $ run (mcmcP MCMCConfig {numBurnIn = burnIn, proposal = SingleSiteMH, numMCMCSteps = -1} distribution) eventChan n
  samples <-
    B.customMain
      initialVty
      buildVty
      (Just eventChan)
      ( ( B.App
            { B.appDraw = drawUI visualizer,
              B.appChooseCursor = B.showFirstCursor,
              B.appHandleEvent = appEvent,
              B.appStartEvent = return,
              B.appAttrMap = const theMap
            }
        )
      )
      (initialState n)
  TL.writeFile "data/tui_output.txt" (pShowNoColor samples)
  return samples
  where
    buildVty = V.mkVty V.defaultConfig
    n = 100000
    initialState n = MCMCData {numSteps = 0, samples = [], lk = [], numSuccesses = 0, totalSteps = n}

    run prod chan i =
      runEffect $
        P.hoist (sampleIO . unweighted) prod
          >-> P.scan
            ( \mcmcdata@(MCMCData ns nsc smples lk _) a ->
                mcmcdata
                  { numSteps = ns + 1,
                    numSuccesses = nsc + if success a then 1 else 0,
                    samples = output (trace a) : smples,
                    lk = exp (ln (probDensity (trace a))) : lk
                  }
            )
            (initialState i)
            id
          >-> P.take i
          >-> P.mapM_ (B.writeBChan chan)
