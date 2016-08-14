module Main where

import Frontend                             (processQuery, processFile)
import Backend                              (infer)
import HopesIO                              (runHopes, HopesContext(..), HopesState(..), Command(..), HopesIO, modify, gets)
import Core                                 (CExpr(..), fromList)
import Error                                (runExceptT)
import Pretty                               (pprint)

import           Pipes.Core

import           Data.Monoid                (mappend, mempty)
import           Control.Monad.Trans        (MonadIO, lift, liftIO)
import           Control.Monad.State.Class  (MonadState(..))
import           System.Console.Haskeline   (runInputT, InputT, getInputLine, defaultSettings)
import           System.IO                  (hSetBuffering, stdin, BufferMode(NoBuffering))
import           System.Environment         (getArgs)

-- temporary imports (to be removed)
import           Operator (Operator(..))


main = do
  args <- getArgs
  runHopes $ do
    mapM_ includeFile args
    prog <- gets assertions
    runInputT defaultSettings $ runEffect (readLine +>> repl)
    return ()

includeFile file = runEffect (executeCommand >\\ (processFile file))

instance MonadState s m => MonadState s (InputT m) where
  state = lift . state

readLine prompt = do
  line <- lift $ getInputLine prompt
  case line of
    Just l -> do
      p <- respond l
      readLine p
    Nothing ->
      return ()

repl :: (Monad m, MonadIO m, MonadState HopesState m) => Proxy String String y0 x0 m ()
repl = loop
  where loop = do
          line <- request "?- "
          e <- lift $ runExceptT $ runEffect $ (queryDriver />/ printResultAndWait) (line :: String)
          case e of
            Left (msgs,errors) -> do
              liftIO $ pprint msgs
              liftIO $ pprint errors
            Right hasResults -> do
              if (hasResults)
              then liftIO $ putStrLn "Yes"
              else liftIO $ putStrLn "No"
          loop


-- printResultAndWait :: (Pretty a, MonadIO m) => a -> m Bool
printResultAndWait result = do
  liftIO $ pprint result
  liftIO $ hSetBuffering stdin NoBuffering
  c <- liftIO $ getChar
  return (c == ';')

-- goalDriver :: (Monad m, MonadError Messages m) =>  String -> Proxy X () Bool ComputedAnswer m ()
queryDriver queryString = do
  g <- lift $ processQuery queryString
  infer g

-- must be moved probably in Backend
--executeCommand :: Command -> HopesIO ()
executeCommand (Assert prog tyEnv)  =
  modify (\e -> e{ assertions = (assertions e) `mappend` (fromList prog)
                 , types = (types e) `mappend` tyEnv
                 })
executeCommand (Command comm) =
  case c comm of
    Just (("op", 3), [CNumber (Left prec),CConst assoc, CConst opname]) -> do
      let op = Operator { opName = opname, opAssoc = assoc }
      modify (\e -> e{operators = (fromIntegral prec :: Int, op):(operators e)})
    Just (("include", 1), [CConst file]) -> do
      lift $ includeFile file
      return ()
    _ -> return ()
  where c (CApp _ (CPred _ p) args) = Just (p, args)
        c _ = Nothing
executeCommand (Query query)  = return ()
