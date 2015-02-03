{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE TemplateHaskell #-}

module KMC.Program.Backends.HasedParser where

import Control.Applicative ((<$>), (<*>), (<*), (*>))
import Control.Monad.Identity (Identity)
import Text.Parsec hiding (parseTest)
import Text.ParserCombinators.Parsec.Expr (Assoc(..), buildExpressionParser, Operator(..))

import KMC.Syntax.Parser (anchoredRegexP)
import KMC.Syntax.External (Regex)
import KMC.Syntax.Config

-- | Change the type of a state in a parser.  
changeState :: forall m s u v a . (Functor m, Monad m)
            => (u -> v) -> (v -> u) -> ParsecT s u m a -> ParsecT s v m a
changeState forward backward = mkPT . transform . runParsecT
  where
    --mapState :: forall u v . (u -> v) -> State s u -> State s v
    mapState f st = st { stateUser = f (stateUser st) }
    --mapReply :: forall u v . (u -> v) -> Reply s u a -> Reply s v a
    mapReply f (Ok a st err) = Ok a (mapState f st) err
    mapReply _ (Error e) = Error e
    --
    fmap3 = fmap . fmap . fmap
    --transform :: (State s u -> m (Consumed (m (Reply s u a))))
    --          -> (State s v -> m (Consumed (m (Reply s v a))))
    transform p st = fmap3 (mapReply forward) (p (mapState backward st))


-- name: Hased : HAskell Stream Editor

-- Grammar:
-- parser ::= . | (name ":=" expr) parser
-- expr   ::= C expr_0 ... expr_1
--          | <E>
--          | !E!
--          | x
--          | expr "|" expr

data Identifier = Identifier String deriving (Show, Eq, Ord)
type ConsName      = String

-- | An assignment is just a name/term pair.
data HasedAssignment  = HA (Identifier, HasedTerm) deriving (Show, Eq, Ord)

-- | A Hased program is a list of assignments.
data Hased            = Hased [HasedAssignment] deriving (Show, Eq, Ord)

-- | The terms describe how regexps are mapped to data.
data HasedTerm = Constructor String [HasedTerm]
               | RE Regex
               | Skip Regex
               | Var Identifier
               | NamedArg Identifier HasedTerm
               | Sum HasedTerm HasedTerm
  deriving (Show, Eq, Ord)

data HPState = HPState { indentLevel :: Int } deriving (Show)

hpInitState :: HPState
hpInitState = HPState { indentLevel = 0 }

type HasedParser a = Parsec String HPState a

{-- Indentation functions --}
    
getIndentation :: HasedParser Int
getIndentation = indentLevel <$> getState

setIndentation :: Int -> HasedParser ()
setIndentation ind = modifyState (\s -> s {indentLevel = ind })

resetIndentation :: HasedParser ()
resetIndentation = setIndentation 0

withHPState :: Parsec s () a -> Parsec s HPState a
withHPState p = getState >>= \hps -> changeState (const hps) (const ()) p


separator :: HasedParser ()
separator = ignore (spaceOrTab <|> try (lookAhead newline))
  
end :: HasedParser ()
end = separator <|> eof

-- Parse one space or tab character.
spaceOrTab :: HasedParser Char
spaceOrTab = char ' ' <|> char '\t'

ignore :: Parsec s u a -> Parsec s u ()
ignore p = p >> return ()

parens :: HasedParser a -> HasedParser a
parens = between (char '(') (char ')')

indent :: HasedParser ()
indent = try (newline >> spaceOrTab) >>
         do
           lvl <- getIndentation
           -- Already read one whitespace above, so add one.
           n <- (+ 1) . length <$> many spaceOrTab 
           setIndentation n

spaceAround :: HasedParser a -> HasedParser a
spaceAround = between (many spaceOrTab) (many spaceOrTab)

-- | Runs the given parser if the predicate on the indentation level is satisfied.
atIndentation :: (Int -> Bool) -> HasedParser a -> HasedParser a
atIndentation pred parser =
    do
      indent
      lvl <- getIndentation
      case pred lvl of
        True  -> parser
        False -> fail $ "at indent level " ++ show lvl -- parserZero

subIndentation :: HasedParser a -> HasedParser a
subIndentation parser = do
  i <- getIndentation
  r <- parser
  setIndentation i
  return r

hasedIdentifier :: HasedParser Identifier
hasedIdentifier = Identifier <$> 
                  ((:) <$> legalStartChar <*> manyTill legalChar end)
                  <?> "identifier"
    where
      legalStartChar = lower
      legalChar = upper <|> lower <|> digit <|> oneOf "_-"

hasedConstructorName :: HasedParser ConsName
hasedConstructorName = (:) <$> legalStartChar <*> manyTill legalChar end
                       <?> "constructor name"
    where
      legalStartChar = upper
      legalChar = upper <|> lower <|> digit <|> char '_'

hasedBecomesToken :: HasedParser ()
hasedBecomesToken = between (many spaceOrTab) (many spaceOrTab) (string ":=" >> return ())

hasedAssignment :: HasedParser HasedAssignment
hasedAssignment = do
  resetIndentation
  ident <- hasedIdentifier
  hasedBecomesToken
  term <- (atIndentation (> 0) hasedTerm) <|> hasedTerm
  return $ HA (ident, term)

hased :: HasedParser Hased
hased = Hased <$> hasedAssignment `sepEndBy` newline

hasedSingleTerm :: HasedParser HasedTerm
hasedSingleTerm =     hasedConstructorTerm
                  <|> hasedPrimTerm
                  <|> hasedNamedArg
                  <|> parens hasedTerm

hasedTerm :: HasedParser HasedTerm
hasedTerm = buildExpressionParser table (spaceAround hasedSingleTerm)
    where
      table = [ [Infix (char '|' >> return Sum) AssocRight] ]

            
hasedConstructorTerm :: HasedParser HasedTerm
hasedConstructorTerm = do
  name <- hasedConstructorName
  i <- getIndentation
  argTerms <- subIndentation $
              do
                l1 <- hasedTerm `sepEndBy` (many spaceOrTab)
                l2 <- concat <$> many (atIndentation (> i)
                                       (hasedTerm `sepEndBy` (many spaceOrTab)))
                return $ l1 ++ l2
              
  -- i <- getIndentation
  -- argTerms <- do
  --   l1 <- hasedTerm `sepEndBy` (many spaceOrTab)
  --   l2 <- concat <$> many (atIndentation (> i)
  --                          (hasedTerm `sepEndBy` (many spaceOrTab)))
  --   setIndentation i
  --   return $ l1 ++ l2
  return $ Constructor name argTerms

hasedNamedArg :: HasedParser HasedTerm
hasedNamedArg = between (char '{') (char '}') $ do
                  many spaceOrTab
                  name <- hasedIdentifier
                  char '='
                  many spaceOrTab
                  arg <- hasedTerm
                  return $ NamedArg name arg

hasedPrimTerm :: HasedParser HasedTerm
hasedPrimTerm = re <|> skip <|> identifier
    where
      re         = RE   <$> between (char '<') (char '>') regexP        <?> "RE"
      skip       = Skip <$> between (char '!') (char '!') regexP        <?> "Skip"
      identifier = Var  <$> try (hasedIdentifier <* notFollowedBy hasedBecomesToken) <?> "Var"

regexP :: HasedParser Regex
regexP = snd <$> (withHPState $ anchoredRegexP (basicRegexParser { rep_illegal_chars = "!<>" }))





-----------------------------------------------------------------
-----------------------------------------------------------------

stateParseTest :: (Stream s Identity t, Show a)
               => u -> Parsec s u a -> s -> IO ()
stateParseTest st p input
    = case runParser p st "" input of
        Left err -> do putStr "parse error at "
                       print err
        Right x  -> print x

parseTest :: (Show a) => HasedParser a -> String -> IO ()
parseTest = stateParseTest hpInitState

parseTest' :: (Stream s Identity t)
               => Parsec s HPState Hased -> s -> IO Hased
parseTest' p input
    = case runParser p hpInitState "" input of
        Left err -> do putStr "parse error at "
                       print err
                       fail ""
        Right x  -> return x

p = parseTest (hasedAssignment <* eof)
t1 = "x := CSV <a|b*> !c*! <def+fed> x"
t11 = unlines [ "x :="
              , " CSV <a|b*> !c*! <def+fed> x"
              ]
p2 = parseTest (hasedTerm <* eof)
t2 = "CSV <a|b*> !c*! <def+fed> x"
t3 = unlines [ "CSV "
             , " <a|b*> "
             , " !c*! "
             , " <def+fed> x"]
t4 = unlines [ "x := CSV <a|b*> !c*! "
             , "   <def+fed> y"
             , "y := Abc <(d|e)*> x"
             ]
t5 = unlines [ "x := CSV <a|b*> "
             , "    !c*! "
             , "    <def+fed> y"
             , "    Abc <(d|e)*> x"
             , "y :="
             , " Cons !re!"
             ]

t6 = unlines [ "x := Cons <E> x "
             , "   | Nil !F!"
             , "y := Cons <E> y"
             , "   | Nil !F!"
             , "y := Snoc { name = <(ab)*> } "
             , "          {address = <E|F>} "
             , " | Nul !(c|e)*!"
             , "newThing := Elm "
             , "   | Elm2 "
             , "  | Elm3 !Q! "
             ]
t7 = unlines [ "x := CSB {name = <E{1,4}>} {address = <F>}"]

pf = parseTest (hased <* eof)
pf' = parseTest' (hased <* eof)
