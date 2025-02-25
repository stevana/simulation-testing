module Moskstraumen.Simulate (module Moskstraumen.Simulate) where

import Data.List (partition)
import qualified Data.List.NonEmpty as NonEmpty
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import qualified Data.Text as Text

import Moskstraumen.Codec
import qualified Moskstraumen.Generate as Gen
import Moskstraumen.Heap (Heap)
import qualified Moskstraumen.Heap as Heap
import Moskstraumen.LinearTemporalLogic
import Moskstraumen.Message
import Moskstraumen.Node4
import Moskstraumen.NodeHandle
import Moskstraumen.NodeId
import Moskstraumen.Prelude
import Moskstraumen.Random
import Moskstraumen.Shrink
import Moskstraumen.Time
import Moskstraumen.Workload

------------------------------------------------------------------------

-- start snippet World
data World m = World
  { nodes :: Map NodeId (NodeHandle m)
  , messages :: Heap Time Message
  , prng :: Prng
  , trace :: Trace
  }

-- end snippet

-- start snippet Trace
type Trace = [Message]

-- end snippet

-- start snippet Deployment
data Deployment m = Deployment
  { numberOfNodes :: Int
  , spawn :: m (NodeHandle m)
  }

-- end snippet

type NumberOfTests = Int

-- start snippet TestConfig
data TestConfig = TestConfig
  { numberOfTests :: Int
  , numberOfNodes :: Int
  , replaySeed :: Maybe Int
  }

-- end snippet

-- start snippet defaultTestConfig
defaultTestConfig :: TestConfig
defaultTestConfig =
  TestConfig
    { numberOfTests = 100
    , numberOfNodes = 5
    , replaySeed = Nothing
    }

-- end snippet

------------------------------------------------------------------------

generateRandomArrivalTimes ::
  Time -> Double -> [Message] -> Prng -> Heap Time Message
generateRandomArrivalTimes now meanMicros = go []
  where
    go acc [] _prng = Heap.fromList acc
    go acc (message : messages) prng =
      let
        (deltaMicros, prng') = exponential meanMicros prng
        arrivalTime = addTimeMicros (round deltaMicros) now
      in
        go ((arrivalTime, message) : acc) messages prng'

-- start snippet stepWorld
stepWorld :: (Monad m) => World m -> m (Either (World m) ())
stepWorld world = case Heap.pop world.messages of
  Nothing -> return (Right ())
  Just ((arrivalTime, message), messages') ->
    case Map.lookup message.dest world.nodes of
      Nothing -> error ("stepWorld: unknown destination node: " ++ show message.dest)
      Just node -> do
        let (prng', prng'') = splitPrng world.prng
        responses <- node.handle arrivalTime message
        let (clientResponses, nodeMessages) =
              partition (isClientNodeId . dest) responses
            meanMicros = 20000 -- 20ms
            nodeMessages' = generateRandomArrivalTimes arrivalTime meanMicros nodeMessages prng'
        return
          $ Left
            World
              { nodes = world.nodes
              , messages = messages' <> nodeMessages'
              , prng = prng''
              , trace = world.trace ++ message : clientResponses
              }
-- end snippet
{-# SPECIALIZE stepWorld :: World IO -> IO (Either (World IO) ()) #-}

-- start snippet runWorld
runWorld :: (Monad m) => World m -> m Trace
runWorld world =
  stepWorld world >>= \case
    Right () -> return world.trace
    Left world' -> runWorld world'
-- end snippet
{-# SPECIALIZE runWorld :: World IO -> IO Trace #-}

-- start snippet newWorld
newWorld ::
  (Monad m) => Deployment m -> [Message] -> Prng -> m (World m)
newWorld deployment initialMessages prng = do
  let nodeIds =
        map
          (NodeId . ("n" <>) . Text.pack . show)
          [1 .. deployment.numberOfNodes]
  nodeHandles <-
    replicateM deployment.numberOfNodes deployment.spawn
  let (prng', prng'') = splitPrng prng
      meanMicros = 20000 -- 20ms
      initialMessages' = generateRandomArrivalTimes epoch meanMicros initialMessages prng'
  return
    World
      { nodes = Map.fromList (zip nodeIds nodeHandles)
      , messages = initialMessages'
      , prng = prng''
      , trace = []
      }

-- end snippet

------------------------------------------------------------------------

-- start snippet TestResult
data TestResult = Success | Failure Trace
  -- end snippet
  deriving stock (Eq, Show)

testResultToMaybe :: TestResult -> Maybe Trace
testResultToMaybe Success = Nothing
testResultToMaybe (Failure trace) = Just trace

-- start snippet runTest
runTest ::
  (Monad m) =>
  Deployment m
  -> Workload
  -> Prng
  -> [Message]
  -> m TestResult
runTest deployment workload prng initialMessages = do
  world <-
    newWorld
      deployment
      initialMessages
      prng
  resultingTrace <- runWorld world
  traverse_ (.close) world.nodes
  if sat workload.property resultingTrace emptyEnv
    then return Success
    else return (Failure resultingTrace)

-- end snippet

-- start snippet runTests
runTests ::
  forall m.
  (Monad m) =>
  Deployment m
  -> Workload
  -> NumberOfTests
  -> Prng
  -> m TestResult
runTests deployment workload numberOfTests0 initialPrng =
  loop numberOfTests0 initialPrng
  where
    loop :: NumberOfTests -> Prng -> m TestResult
    loop 0 _prng = return Success
    loop n prng = do
      let (prng', initialMessages) = generate 100 prng -- XXX: vary size over time...
      let (prng'', prng''') = splitPrng prng'
      result <- runTest deployment workload prng'' initialMessages
      case result of
        Success -> loop (n - 1) prng'''
        Failure _unShrunkTrace -> do
          initialMessagesAndTrace <-
            shrink
              (fmap testResultToMaybe . runTest deployment workload prng)
              (shrinkList (const []))
              initialMessages
          let (_shrunkMessages, shrunkTrace) = NonEmpty.last initialMessagesAndTrace
          return (Failure shrunkTrace)

    generate :: Int -> Prng -> (Prng, [Message])
    generate size prng =
      let initMessages =
            [ makeInitMessage (makeNodeId i) (map makeNodeId js)
            | i <- [1 .. deployment.numberOfNodes]
            , let js = [j | j <- [1 .. deployment.numberOfNodes], j /= i]
            ]

          (prng', initialMessages) =
            Gen.runGen (Gen.listOf workload.generateMessage) prng size

          messages :: [Message]
          messages =
            zipWith
              ( \message index -> message {body = message.body {msgId = Just index}}
              )
              (initMessages <> initialMessages)
              [0 ..]
      in  (prng', messages)

-- end snippet

------------------------------------------------------------------------

-- start snippet blackboxTest
blackboxTestWith :: TestConfig -> FilePath -> Workload -> IO Bool
blackboxTestWith testConfig binaryFilePath workload = do
  (prng, seed) <- newPrng testConfig.replaySeed
  let deployment =
        Deployment
          { numberOfNodes = testConfig.numberOfNodes
          , spawn = pipeSpawn binaryFilePath seed
          }
  let (prng', _prng'') = splitPrng prng
  result <- runTests deployment workload testConfig.numberOfTests prng'
  case result of
    Failure trace -> do
      putStrLn ("Seed: " <> show seed)
      print trace
      return False
    Success -> return True

blackboxTest :: FilePath -> Workload -> IO Bool
blackboxTest = blackboxTestWith defaultTestConfig

-- end snippet

simulationTestWith ::
  TestConfig
  -> (input -> Node state input output)
  -> state
  -> ValidateMarshal input output
  -> Workload
  -> IO Bool
simulationTestWith testConfig node initialState validateMarshal workload = do
  (prng, seed) <- newPrng testConfig.replaySeed
  let (prng', prng'') = splitPrng prng
  let deployment =
        Deployment
          { numberOfNodes = testConfig.numberOfNodes
          , spawn = simulationSpawn node initialState prng' validateMarshal
          }
  result <- runTests deployment workload testConfig.numberOfTests prng''
  case result of
    Failure trace -> do
      putStrLn ("Seed: " <> show seed)
      print trace
      return False
    Success -> return True

simulationTest ::
  (input -> Node state input output)
  -> state
  -> ValidateMarshal input output
  -> Workload
  -> IO Bool
simulationTest = simulationTestWith defaultTestConfig
