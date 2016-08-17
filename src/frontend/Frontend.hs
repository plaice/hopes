--  Copyright (C) 2016 Angelos Charalambidis  <a.charalambidis@di.uoa.gr>
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

module Frontend (
    processFile
  , processQuery
  ) where

import           HopesIO   (HopesIO, liftHopes, HopesContext(..), HopesState(..), Command(..), operators, types, gets, asks, modify, withFilename, logMsg)
import           Error
import           Loc       (LocSpan)
import           Syntax    (SSent, isCommand)
import           TypeCheck (runTcT, Tc, TcOutput(..), withEnvPreds, initTcEnv, tcProg, tcGoal)
import           Parser    (runPT, ParseState(ParseSt), maybeOrEof, sentence, query, ParsecT, Stream, buildTable, updateState)
import qualified Parser    (operators)
import           Prepr     (sentencesToProg)
import           Desugar   (desugarProg, desugarGoal)

import           Pipes
import           Pipes.Core
import qualified Pipes.Prelude    as P

import qualified Data.ByteString  as ByteString
import           Control.Monad    (when, join)
import           System.FilePath  ((</>), normalise)
import           System.Directory (canonicalizePath)



processFile :: FilePath -> Proxy Command () () X HopesIO (Either Messages ())
processFile filename = do
  dir <- liftHopes $ asks workingDirectory
  absoluteFilename <- liftIO $ canonicalizePath (normalise $ dir </> filename)
  lift $ logMsg $ "Loading " ++ absoluteFilename
  input <- liftIO $ ByteString.readFile absoluteFilename
  r <- withFilename absoluteFilename $
    runPipeline absoluteFilename input pipeline
  lift $ logMsg $ "Loaded " ++ absoluteFilename
  return r

--runPipeline :: SourceName -> ByteString -> Effect (Loader HopesIO) () -> HopesIO (Either Messages ())
runPipeline filename input p = do
            op <- liftHopes $ gets operators
            r <- runPT (buildTable >> runTcT initTcEnv (runEffect p)) (parseState op) filename input
            return (join r)
        where parseState op = ParseSt op [] [] []


--groupUntil :: Monad m => (a -> Bool) -> Producer' a m r -> Producer' [a] m r
groupUntil predicate p = go id p
  where
    go diffAs p = do
      x <- lift (next p)
      case x of
        Left r ->
          case (diffAs []) of
            []    -> return r
            (x:xs) -> do
              yield (x:xs)
              return r
        Right (a, p') ->
            if (predicate a)
              then do
                yield ((diffAs . (a:)) [])
                go id p'
              else go (diffAs . (a:)) p'

parse :: (Monad m, Stream s m Char) => Producer (SSent LocSpan) (Tc a (ParsecT s (ParseState s m) m)) ()
parse = do
    r <- lift $ lift $ maybeOrEof sentence
    case r of
      Just r' -> yield r' >> parse
      Nothing -> return ()

typeCheck = P.map sentencesToProg >-> (tc [])

tc env = do
    dag <- await
    tcOut <- lift (withEnvPreds env $ tcProg dag)
    yield tcOut
    tc (tcOutPreds tcOut)

toCore = P.map (\tcout -> (desugarProg (tcOutSyntax tcout), tcOutPreds tcout))

toCommands = do
  ((prog, commands, goals), tyenv) <- await
  when (not (null prog)) (yield (Assert prog tyenv))
  when (not (null commands)) $
    each $ map (Command) commands
  when (not (null goals)) $
    each $ map (Query) goals
  toCommands

pipeline = groupUntil isCommand parse >->
            typeCheck >->
            toCore >->
            toCommands >->
            P.mapM_ execCommand
      where execCommand x = do
                lift $ lift $ request x
                ops <- liftHopes $ (gets operators)
                lift $ updateState (\st -> st{ Parser.operators = ops})
                lift $ buildTable

--goalDriver :: String -> HopesIO ()
processQuery queryString = do
    e <- parse queryString
    e' <- typeCheck e
    return (desugarGoal e')
    where parse input = exceptT $ do
              op <- gets operators
              runPT query (parseState op) "stdin" input
          typeCheck e = exceptT $ do
              tyenv <- gets types
              tye <- runTcT initTcEnv $ withEnvPreds tyenv $ tcGoal e
              return tye
          parseState op = ParseSt op [] [] []
