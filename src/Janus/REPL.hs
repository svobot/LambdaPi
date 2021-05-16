{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE FlexibleContexts #-}

-- | REPL interface for the Janus language.
--
-- Interpreter reads user's input, evaluates it, and prints the result in
-- an infinite loop. The input can either be a statement, see below, or
-- a command. Commands are identified by a leading colon. Some commands expect
-- arguments, which should follow the command. Janus interpreter supports
-- the following commands:
--
--   * /load/ takes a file path and it opens the file and evaluates its
--   contents.
--
--   * /browse/ lists all the variables that are currently in scope, annotated
--   with their types.
--
--   * /type/ takes a Janus term and synthesises its type.
--
--   * /quit/ exits the interpreter.
--
--   * /help/ shows a short description of the interpreter's features.
--
-- For example, the following command loads the contents of the file
-- /library.jns/:
--
-- @
-- >>> :load library.jns
-- /... output produced by the evaluation of terms read from the file .../
-- @
--
-- === Statements
--
-- If no command is specified, interpreter expects the input to be a statement,
-- which is evaluated, and the result is printed out. Statements are:
--
--   * /assume/ introduces new names and adds them to the context, subsequent
--   Janus terms will have these variables in scope.
--
-- @
-- >>> assume (/usage/ /name/ : /term/) /.../
--               │    │      │     │
--               │    │      │     └─ Multiple variables can be added
--               │    │      │        to context at the same time.
--               │    │      └─────── Janus term which defines the type.
--               │    └────────────── Name of the new variable.
--               └─────────────────── Multiplicity of the variable.
--                                    This is optional and when omitted,
--                                    interpreter defaults to ω.
-- @
--
--   * /let/ defines a new variable and assigns it a result of evaluated Janus
--   term.
--
-- @
-- >>> let /usage/ /name/ = /term/
--           │    │      │
--           │    │      └─────────── Janus term which creates the value.
--           │    └────────────────── Name of the new variable.
--           └─────────────────────── Multiplicity of the variable.
--                                    This is optional and when omitted,
--                                    interpreter defaults to ω.
-- @
--
--   * /eval/ statement is a Janus expression which get evaluated and its result
--   is printed. /eval/ has no effect on variables in scope.
--
-- @
-- >>> /usage/ /term/
--       │    │
--       │    └────────────────────── Janus term which creates the value.
--       └─────────────────────────── Multiplicity of the result.
--                                    This is optional and when omitted,
--                                    interpreter defaults to ω.
-- @
--
-- === An example of an interactive programming session
--
-- Declare a variable @A@ of type 'Universe' without a computational presence
-- and a linear variable @x@ of type @A@:
--
-- > >>> assume (0 A : U) (1 x : A)
-- > 0 A : 𝘜
-- > 1 x : A
--
-- Define a variable @id@ as an identity function. Its parameter @y@ is a linear
-- variable, so the function body has to use it exactly once:
--
-- > >>> let 1 id = \x. \y. y : (0 x : 𝘜) -> (1 y : x) -> x
-- > 1 id = (λx y. y) : ∀ (0 x : 𝘜) (1 y : x) . x
--
-- Examine the variable in scope using the /browse/ command:
--
-- > >>> :browse
-- > 0 A : 𝘜
-- > 1 x : A
-- > 1 id : ∀ (0 x : 𝘜) (1 y : x) . x
--
-- Evaluate the identity function application:
--
-- > >>> 1 id A       -- Partially applied function, resulting in an identity function on type A.
-- > 1 (λx. x) : (1 x : A) → A
-- > >>> 1 id A x     -- Fully applied function, resulting in the value of type A.
-- > 1 x : A
--
-- As an example of incorrect term, we try to construct a pair of identity
-- functions. The variable @id@ is however linear, so it can be used only once
-- in a term.
--
-- > >>> let 0 id_type = (0 x : 𝘜) -> (1 y : x) -> x : U     -- We define a helper variable to make the terms more readable.
-- > 0 id_type = (∀ (0 x : 𝘜) (1 y : x) . x) : 𝘜
-- > >>> let 1 pair = (id, id) : (_ : id_type) * id_type
-- > error: Mismatched multiplicities:
-- >         id : ∀ (0 x : 𝘜) (1 y : x) . x
-- >           Used ω-times, but available 1-times.
--
module Janus.REPL
  ( IState(..)
  , MonadAbstractIO(..)
  , compileStmt
  , repl
  ) where

import           Control.Exception              ( IOException
                                                , try
                                                )
import           Control.Monad.State            ( MonadIO
                                                , MonadState(..)
                                                , StateT
                                                , evalStateT
                                                , forM_
                                                , gets
                                                , liftIO
                                                , modify
                                                , unless
                                                )
import           Data.Bifunctor                 ( bimap
                                                , second
                                                )
import           Data.Char                      ( isSpace )
import           Data.Function                  ( on )
import           Data.List                      ( dropWhileEnd
                                                , intercalate
                                                , isPrefixOf
                                                , nub
                                                , nubBy
                                                )
import           Data.Maybe                     ( isNothing )
import qualified Data.Text                     as T
import qualified Data.Text.IO                  as T
import           Janus.Parser
import           Janus.Printer
import           Janus.Semiring
import           Janus.Types
import           Janus.Typing
import           System.Console.Repline
import           Text.Parsec                    ( ParseError )

-- | The 'MonadAbstractIO' class defines monadic actions which are used by our
-- interpreter to output its results.
class (Monad m) => MonadAbstractIO m where
  output :: String -> m ()
  outputDoc :: Doc -> m ()
  outputFile :: FilePath -> T.Text -> m ()

instance (Monad m, MonadIO m) => MonadAbstractIO (HaskelineT m) where
  output     = liftIO . putStrLn
  outputDoc  = liftIO . T.putStrLn . render
  outputFile = (liftIO .) . T.writeFile

-- | State of the interpreter, which holds the types and values of previously
-- evaluated expressions.
data IState = IState
  { outFile :: String
  , context :: Context
  }

type Repl = HaskelineT (StateT IState IO)

type AbstractRepl m = (MonadState IState m, MonadAbstractIO m)

-- | Character which identifies a command.
--
-- For example, user types @:load@ if they want to invoke the /load/ command.
commandPrefix :: Char
commandPrefix = ':'

-- | Pairings of input prefixes and completion functions which are invoked for
-- the subsequent input if existing input matches the prefix.
defaultMatcher :: (MonadIO m) => [(String, CompletionFunc m)]
defaultMatcher =
  [ (commandPrefix : "load ", fileCompleter)
  , (commandPrefix : "l "   , fileCompleter)
  , ([commandPrefix]        , wordCompleter commandCompleter)
  ]

-- | Complete a command.
commandCompleter :: Monad m => WordCompleter m
commandCompleter n =
  return
    . filter (n `isPrefixOf`)
    . map (commandPrefix :)
    . concatMap cmdNames
    $ commands

-- | Complete a known variable or a keyword.
byWord :: (MonadState IState m) => WordCompleter m
byWord n = do
  env <- gets $ snd . context
  let scope = [ s | Global s <- reverse . nub $ map bndName env ]
  return . filter (n `isPrefixOf`) $ scope ++ keywords

data CmdInfo = CmdInfo
  { cmdNames  :: [String]
  , cmdArgs   :: Maybe String
  , cmdDesc   :: String
  , cmdAction :: Cmd Repl
  }

-- | List of REPL commands and their descriptions.
commands :: [CmdInfo]
commands =
  [ CmdInfo ["type"] (Just "<expr>") "print type of expression" typeOf
  , CmdInfo ["browse"] Nothing "browse names in scope" browse
  , CmdInfo ["load"] (Just "<file>") "load program from file" compileFile
  , CmdInfo ["quit"] Nothing "exit interpreter" (const abort)
  , CmdInfo ["help", "?"] Nothing "display this list of commands" help
  ]

-- | Print a help message.
help :: Cmd Repl
help _ = liftIO $ do
  putStrLn
    "List of commands:  Any command may be abbreviated to its unique prefix.\n"
  putStrLn $ intercalate "\n" helpLines
 where
  aliases args =
    intercalate ", " . map ((++ maybe "" (' ' :) args) . (commandPrefix :))
  cols =
    [ ("<expr>"               , "evaluate expression")
      , ("let <var> = <expr>"   , "define variable")
      , ("assume <var> : <expr>", "assume variable\n")
      ]
      ++ map ((,) <$> (aliases <$> cmdArgs <*> cmdNames) <*> cmdDesc) commands
  spaces colWidth cmd = replicate (colWidth + 2 - length cmd) ' '
  fmt w (c, desc) = c <> spaces w c <> desc
  helpLines = map (fmt . maximum $ map (length . fst) cols) cols

-- | Synthesise the type of a term and print it.
typeOf :: Cmd Repl
typeOf s = do
  mx  <- parseIO typeParser s
  ctx <- gets context
  t   <- maybe (return Nothing) (uncurry (iinfer ctx)) mx
  mapM_ (liftIO . T.putStrLn . render . pretty) t

-- | Print types of variables in the context.
browse :: Cmd Repl
browse _ = do
  env <- gets $ snd . context
  mapM_ (liftIO . T.putStrLn . render . pretty)
    . reverse
    . map (\b -> b { bndName = vfree $ bndName b })
    $ nubBy ((==) `on` bndName) env

-- | Parse and evaluate an input.
compileStmt :: AbstractRepl m => String -> m ()
compileStmt x = parseIO evalParser x >>= mapM_ handleStmt

-- | Parse and evaluate a file.
--
-- File contains a sequence of statements which are evaluated in order.
compileFile :: Cmd Repl
compileFile f = do
  x' <-
    liftIO
    . (try @IOException . readFile)
    . dropWhile isSpace
    . dropWhileEnd isSpace
    $ f
  case x' of
    Left  e -> liftIO $ print e
    Right x -> parseIO (fileParser f) x >>= mapM_ (mapM_ handleStmt)

-- | Synthesise the type of a term and print an error if it occurs.
iinfer :: AbstractRepl m => Context -> ZeroOneMany -> ITerm -> m (Maybe Type)
iinfer g r t = case synthesise g r t of
  Left  e -> outputDoc (pretty e) >> return Nothing
  Right v -> return (Just v)

-- | Run a parser and print an error if it occurs.
parseIO :: MonadAbstractIO m => (a -> Either ParseError b) -> a -> m (Maybe b)
parseIO p x = case p x of
  Left  e -> output (show e) >> return Nothing
  Right r -> return (Just r)

-- | Perform an action specified by the statement.
handleStmt :: AbstractRepl m => Stmt -> m ()
handleStmt stmt = case stmt of
  Assume bs  -> mapM_ assume bs
  Let q x e  -> checkEval q (Just x) e
  Eval q e   -> checkEval q Nothing e
  PutStrLn x -> output x
  Out      f -> modify $ \st -> st { outFile = f }
 where
  mapContext f = \st -> st { context = f $ context st }

  assume (Binding x q t) = do
    let annt = Ann t Universe
    ctx <- gets context
    mty <- iinfer ctx Zero annt
    unless (isNothing mty) $ do
      let val = iEval (fst ctx, []) annt
      outputDoc . pretty $ Binding (vfree $ Global x) q val
      modify . mapContext $ second (Binding (Global x) q val :)

  checkEval q mn t = do
    ctx <- gets context
    mty <- iinfer ctx q t
    forM_ mty $ \ty -> do
      let val    = iEval (fst ctx, []) t
      let outdoc = prettyResult q mn val ty
      outputDoc outdoc
      out <- gets outFile
      unless (null out) $ do
        let process = T.unlines . map ("< " <>) . T.lines
        outputFile out . process $ render outdoc
        modify $ \st -> st { outFile = "" }
      forM_ mn $ \n -> modify . mapContext $ bimap ((Global n, val) :)
                                                   (Binding (Global n) q ty :)

ini :: Repl ()
ini = liftIO $ putStrLn "Interpreter for Janus.\nType :? for help."

final :: Repl ExitDecision
final = do
  liftIO $ putStrLn "Leaving Janus interpreter."
  return Exit

-- | Evaluate the REPL monad and its inner state.
repl :: IO ()
repl = flip evalStateT (IState "" ([], [])) $ evalRepl
  (const $ pure ">>> ")
  compileStmt
  (concatMap (traverse (,) <$> cmdNames <*> cmdAction) commands)
  (Just commandPrefix)
  Nothing
  (Combine (Prefix (wordCompleter byWord) defaultMatcher)
           (Word commandCompleter)
  )
  ini
  final

