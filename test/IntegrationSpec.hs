{-# LANGUAGE LambdaCase #-}

module IntegrationSpec
  ( spec
  ) where

import           Control.Monad.State            ( foldM )
import           Data.Bifunctor                 ( first
                                                , second
                                                )
import qualified Parser                        as Parse
import           Printer
import           Rig
import           Test.Hspec              hiding ( context )
import           Text.Parsec                    ( ParseError
                                                , parse
                                                )
import           Types
import           Typing

data TestCase = TestCase
  { desc  :: String
  , setup :: [String]
  , expr  :: String
  , res   :: Result String
  }

data SetupError = PE ParseError | TE TypeError

newtype TestState = TestState { unState :: Either SetupError IState }

cases :: [TestCase]
cases =
  [ TestCase "Identity application"
             ["assume (0 a : U) (1 x : a)"]
             "(\\x. \\y. y : (0 x : U) -> (1 y : x) -> x) a x"
             (return "1 x : a")
  , TestCase "Let identity application"
             ["assume (0 a : U) (1 x : a)"]
             "let 1 id = (\\x. \\y. y : (0 x : U) -> (1 y : x) -> x) a x"
             (return "id = 1 x : a")
  , TestCase "Unknown variable in setup"
             ["assume (0 a : U) (1 x : b)"]
             ""
             (Left . UnknownVar $ Global "b")
  , TestCase
    "Erased linear variables in additive pair"
    ["assume (0 a : U) (0 b : U) (1 x : a) (1 y : b)"]
    "let 0 add = <x, y> : (x : a) & b"
    (Left $ MultiplicityError
      Nothing
      [(Global "x", tyName "a", Zero, One), (Global "y", tyName "b", Zero, One)]
    )
  ]
  where tyName = VNeutral . NFree . Global


setContext :: [String] -> IO TestState
setContext s = return . TestState $ do
  stmts <- first PE (parseSetup s)
  foldM
    (\st stmt -> case stmt of
      (Parse.Assume bs) -> foldM
        (\st' (Binding x q t) -> do
          _ <- first TE $ iType0 (context st') Zero (Ann t Universe)
          let val = iEval (Ann t Universe) (fst $ context st, [])
          return $ st'
            { context = second (Binding (Global x) q val :) $ context st'
            }
        )
        st
        bs
      _ -> undefined
    )
    (IState "" ([], []))
    stmts
 where
  parseSetup :: [String] -> Either ParseError [Parse.Stmt]
  parseSetup = traverse (parse (Parse.stmt []) "<setup>")

run :: TestCase -> Spec
run c = before (setContext $ setup c) (runTestCase c)
 where
  runTestCase :: TestCase -> SpecWith TestState
  runTestCase tc = it (desc tc) . flip (.) unState $ \case
    (Left  (PE e)) -> expectationFailure $ show e
    (Left  (TE e)) -> Left e `shouldBe` res tc
    (Right st    ) -> case parse (Parse.stmt []) "<test>" (expr tc) of
      Left e -> expectationFailure $ show e
      Right (Parse.Eval i) ->
        checkEval (context st) Nothing One i `shouldBe` res tc
      Right (Parse.Let q n i) ->
        checkEval (context st) (Just n) q i `shouldBe` res tc
      _ -> undefined

  checkEval ctx n q i = do
    ty <- iType0 ctx q i
    let val = iEval i (fst ctx, [])
    return $ renderTest n (Binding val q ty)

spec :: Spec
spec = do
  mapM_ run cases