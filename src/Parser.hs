module Parser where

import           Control.Monad.Trans            ( liftIO )
import           Data.List                      ( elemIndex )
import           Data.Maybe                     ( fromMaybe )
import           Text.Parsec
import           Text.Parsec.Language           ( haskellStyle )
import           Text.Parsec.String             ( GenParser )
import           Text.Parsec.Token
import           Types
import           Rig                            ( ZeroOneMany(..) )

lambdaPi :: TokenParser u
lambdaPi = makeTokenParser
  (haskellStyle
    { identStart    = letter <|> char '_'
    , reservedNames = [ "forall"
                      , "let"
                      , "assume"
                      , "putStrLn"
                      , "out"
                      , "in"
                      , "Unit"
                      ]
    }
  )

type CharParser st = GenParser Char st
data Origin = OAnn | OApp | OITerm | OCTerm | OStale deriving (Eq)

data Stmt
  = Let ZeroOneMany String ITerm          --  let x = t
  | Assume [(ZeroOneMany, String, CTerm)] --  assume x :: t, assume x :: *
  | Eval ITerm
  | PutStrLn String --  lhs2TeX hacking, allow to print "magic" string
  | Out String      --  more lhs2TeX hacking, allow to print to files
  deriving (Show, Eq)

parseIO :: String -> CharParser () a -> String -> Repl (Maybe a)
parseIO f p x = case parse (whiteSpace lambdaPi *> p <* eof) f x of
  Left  e -> liftIO $ print e >> return Nothing
  Right r -> return (Just r)

parseStmt :: [String] -> CharParser () Stmt
parseStmt e = choice [try define, assume, putstr, out, eval]
 where
  define = do
    reserved lambdaPi "let"
    q <- optionMaybe parseRig
    x <- identifier lambdaPi
    reserved lambdaPi "="
    t <- parseITerm OITerm e
    return (Let (fromMaybe Many q) x t)
  assume = Assume . reverse <$> (reserved lambdaPi "assume" *> parseAssume)
  putstr =
    PutStrLn <$> (reserved lambdaPi "putStrLn" *> stringLiteral lambdaPi)
  out  = Out <$> (reserved lambdaPi "out" *> option "" (stringLiteral lambdaPi))
  eval = Eval <$> parseITerm OITerm e

parseRig :: CharParser () ZeroOneMany
parseRig = choice
  [ Zero <$ reserved lambdaPi "0"
  , One <$ reserved lambdaPi "1"
  , Many <$ reserved lambdaPi "w"
  ]

parseITerm :: Origin -> [String] -> CharParser () ITerm
parseITerm b e =
  choice
    $  [ try ann | b /= OAnn && b /= OApp ]
    ++ [ try $ parseApp e | b /= OApp ]
    ++ [ try parsePairElim
       , parseUnitElim
       , var
       , parens lambdaPi $ parseITerm OITerm e
       ]
 where
  ann =
    Ann
      <$> parseCTerm (if b == OCTerm then OStale else OAnn) e
      <*  reservedOp lambdaPi ":"
      <*> parseCTerm OAnn e
  parsePairElim = do
    reserved lambdaPi "let"
    z <- identifier lambdaPi
    reservedOp lambdaPi "@"
    x <- identifier lambdaPi
    reservedOp lambdaPi ","
    y <- identifier lambdaPi
    reservedOp lambdaPi "="
    m <- parseITerm OITerm e
    reserved lambdaPi "in"
    n <- parseCTerm OCTerm ([y, x] ++ e)
    reservedOp lambdaPi ":"
    t <- parseCTerm OCTerm (z : e)
    return $ PairElim m n t
  parseUnitElim = do
    reserved lambdaPi "let"
    x <- identifier lambdaPi
    reservedOp lambdaPi "@"
    _ <- parseUnit
    reservedOp lambdaPi "="
    m <- parseITerm OITerm e
    reserved lambdaPi "in"
    n <- parseCTerm OCTerm e
    reservedOp lambdaPi ":"
    t <- parseCTerm OCTerm (x : e)
    return $ UnitElim m n t
  var = do
    x <- identifier lambdaPi
    case elemIndex x e of
      Just n  -> return (Bound n)
      Nothing -> return (Free $ Global x)

parseCTerm :: Origin -> [String] -> CharParser () CTerm
parseCTerm b e =
  choice
    $  [ parseLam e
       , parseStar
       , try parsePi
       , try parsePair
       , try parseTensPr
       , try parseUnit
       , parseUnitType
       , parens lambdaPi $ parseCTerm OCTerm e
       ]
    ++ [ Inf <$> parseITerm b e | b /= OStale ]
 where
  parseStar = Star <$ reserved lambdaPi "*"
  parsePi   = do
    (e', (q, t)) <- parens lambdaPi $ parseBind e
    reservedOp lambdaPi "->"
    p <- parseCTerm OCTerm (e' : e)
    return (Pi q t p)
  parsePair =
    parens lambdaPi
      $   Pair
      <$> parseCTerm OCTerm e
      <*  reservedOp lambdaPi ","
      <*> parseCTerm OCTerm e
  parseTensPr = do
    (e', (q, t)) <- parens lambdaPi $ parseBind e
    reservedOp lambdaPi "*"
    p <- parseCTerm OCTerm (e' : e)
    return $ TensPr q t p
  parseUnitType = UnitType <$ reserved lambdaPi "Unit"

parseUnit :: CharParser () CTerm
parseUnit = Unit <$ reservedOp lambdaPi "(" <* reservedOp lambdaPi ")"

parseLam :: [String] -> CharParser () CTerm
parseLam e = do
  reservedOp lambdaPi "\\"
  xs <- many1 (identifier lambdaPi)
  reservedOp lambdaPi "."
  t <- parseCTerm OCTerm (reverse xs ++ e)
  return (iterate Lam t !! length xs)

parseApp :: [String] -> CharParser () ITerm
parseApp e = foldl (:@:) <$> parseITerm OApp e <*> many1 (parseCTerm OApp e)

parseBind :: [String] -> CharParser () (String, (ZeroOneMany, CTerm))
parseBind e = do
  q <- optionMaybe parseRig
  x <- identifier lambdaPi
  reservedOp lambdaPi ":"
  t <- parseCTerm OCTerm e
  return (x, (fromMaybe Many q, t))

parseAssume :: CharParser () [(ZeroOneMany, String, CTerm)]
parseAssume = snd <$> rec [] [] where
  rec
    :: [String]
    -> [(ZeroOneMany, String, CTerm)]
    -> CharParser () ([String], [(ZeroOneMany, String, CTerm)])
  rec e bs = do
    (x, (q, c)) <- parens lambdaPi $ parseBind []
    rec (x : e) ((q, x, c) : bs) <|> return (x : e, (q, x, c) : bs)

