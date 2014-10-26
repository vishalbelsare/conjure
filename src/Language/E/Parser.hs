{-# LANGUAGE QuasiQuotes, ViewPatterns, OverloadedStrings #-}
{-# LANGUAGE FlexibleContexts #-}

module Language.E.Parser
    ( Parser
    , inCompleteFile
    , parseExpr, parseDomain
    , parseSpec, parseRuleRefn, parseRuleRepr
    , runLexerAndParser, lexAndParse, lexAndParseIO
    , parseTopLevels
    ) where

-- conjure
import Conjure.Prelude
import Conjure.Bug
import Language.E.Definition
import Language.E.Lexer ( Lexeme(..), LexemePos, lexemeFace, lexemeText, runLexer )
import Language.E.Data ( Fixity(..), operators, functionals )
import Language.E.Pretty ( Pretty(pretty) )

-- parsec
import Text.Parsec ( ParsecT, parse, tokenPrim, try, (<?>) )
import Text.Parsec.Combinator ( between, optionMaybe, sepBy, sepBy1, sepEndBy1, eof )

-- text
import qualified Data.Text as T

-- pretty-print
import qualified Text.PrettyPrint as Pr




_testParsePrint :: T.Text -> IO ()
_testParsePrint = _testParsePrint' (inCompleteFile parseExpr)

lexAndParseIO :: Parser a -> T.Text -> IO a
lexAndParseIO p t = do
    case lexAndParse p t of
        Left  e -> error  $ show e
        Right x -> return x

lexAndParse :: Parser a -> T.Text -> Either Doc a
lexAndParse p t = runLexerAndParser p "" t

parseSpec :: Parser Spec
parseSpec = inCompleteFile $ do
    let
        pLanguage :: Parser LanguageVersion
        pLanguage = do
            l  <- lexeme L_language *> identifierText
            is <- sepBy1 integer dot
            return (LanguageVersion (Name l) (map fromInteger is))
    l  <- pLanguage
    xs <- many parseTopLevels
    return $ Spec l $ listAsStatement $ concat xs

parseRuleRefn :: T.Text -> Parser [RuleRefn]
parseRuleRefn t = inCompleteFile $ do
    level <- optionMaybe (brackets (fromInteger <$> integer))
    let
        one = do
            pattern   <- parseExpr
            templates <- some (lexeme L_SquigglyArrow >> parseExpr)
            locals    <- concat <$> many parseTopLevels
            return RuleRefn { ruleRefnName = Name t
                            , ruleRefnLevel = level
                            , ruleRefnPattern = pattern
                            , ruleRefnTemplates = templates
                            , ruleRefnLocals = locals
                            }
    some one

parseRuleReprCase :: Parser RuleReprCase
parseRuleReprCase = do
    lexeme L_CaseSeparator
    dom    <- parseDomain
    mcons  <- optionMaybe (lexeme L_SquigglyArrow >> parseExpr)
    locals <- concat <$> many parseTopLevels
    return (RuleReprCase dom mcons locals)


parseRuleRepr :: T.Text -> Parser RuleRepr
parseRuleRepr t = inCompleteFile $ do
    let arr i = lexeme L_SquigglyArrow >> i
    nmRepr <- arr identifierText
    domOut <- arr parseDomain
    mcons  <- optionMaybe $ arr parseExpr
    locals <- concat <$> many parseTopLevels
    cases  <- some parseRuleReprCase
    return ( RuleRepr (Name t)
             (Name nmRepr)
             domOut
             mcons
             locals
             cases )

parseTopLevels :: Parser [E]
parseTopLevels = do
    let one = msum $ map try
                [ do
                    lexeme L_find
                    decls <- flip sepEndBy1 comma $ do
                        is <- parseReference `sepEndBy1` comma
                        j  <- colon >> parseDomain
                        return [ [xMake| topLevel.declaration.find.name   := [i]
                                       | topLevel.declaration.find.domain := [D j]
                                       |]
                               | i <- is ]
                    return $ concat decls
                    <?> "find statement"
                , do
                    lexeme L_given
                    decls <- flip sepEndBy1 comma $ do
                        is <- parseReference `sepEndBy1` comma
                        msum
                            [ do
                                colon
                                j <- parseDomain
                                return [ [xMake| topLevel.declaration.given.name   := [i]
                                               | topLevel.declaration.given.domain := [D j]
                                               |]
                                       | i <- is ]
                            , do
                                lexeme L_new
                                msum
                                    [ do
                                        lexeme L_type
                                        lexeme L_enum
                                        return [ [xMake| topLevel.declaration.given.name     := [i]
                                                       | topLevel.declaration.given.typeEnum := []
                                                       |]
                                               | i <- is ]
                                    , do
                                        lexeme L_domain
                                        lexeme L_int
                                        return [ [xMake| topLevel.declaration.given.name    := [i]
                                                       | topLevel.declaration.given.typeInt := []
                                                       |]
                                               | i <- is ]
                                    ]
                            ]
                    return $ concat decls
                    <?> "given statement"
                , do
                    lexeme L_letting
                    decls <- flip sepEndBy1 comma $ do
                        is <- (try parseMetaVariable <|> parseReference) `sepEndBy1` comma
                        lexeme L_be
                        msum
                            [ do
                                lexeme L_new
                                lexeme L_type
                                msum
                                    [ do
                                        lexeme L_of
                                        lexeme $ LIdentifier "size"
                                        j <- parseExpr
                                        return [ [xMake| topLevel.letting.name := [i]
                                                       | topLevel.letting.typeUnnamed := [j]
                                                       |]
                                               | i <- is
                                               ]
                                    , do
                                        lexeme L_enum
                                        ys <- braces (parseReference `sepBy` comma) <|> return []
                                        return [ [xMake| topLevel.letting.name := [i]
                                                       | topLevel.letting.typeEnum.values := ys
                                                       |]
                                               | i <- is
                                               ]
                                    ]
                            , do
                                lexeme L_domain
                                j <- parseDomain
                                return [ [xMake| topLevel.letting.name   := [i]
                                               | topLevel.letting.domain := [D j]
                                               |]
                                       | i <- is
                                       ]
                            , do
                                j <- parseExpr
                                return [ [xMake| topLevel.letting.name := [i]
                                               | topLevel.letting.expr := [j]
                                               |]
                                       | i <- is
                                       ]
                            , do
                                j <- parseLambda L_lambda
                                return [ [xMake| topLevel.letting.name   := [i]
                                               | topLevel.letting.lambda := [j]
                                               |]
                                       | i <- is
                                       ]
                            , do
                                j <- parseQuanDecl
                                return [ [xMake| topLevel.letting.name       := [i]
                                               | topLevel.letting.quantifier := [j]
                                               |]
                                       | i <- is
                                       ]
                            ]
                    return $ concat decls
                    <?> "letting statement"
                , do
                    lexeme L_dim
                    is <- parseReference `sepEndBy1` comma
                    j  <- colon >> parseDomain
                    return [ [xMake| topLevel.declaration.dim.name   := [i]
                                   | topLevel.declaration.dim.domain := [D j]
                                   |]
                           | i <- is
                           ]
                    <?> "dim statement"
                , do
                    let dimfind = do
                            lexeme L_find
                            i <- parseExpr
                            colon
                            j <- parseDomain
                            return [xMake| dimFind.name   := [i]
                                         | dimFind.domain := [D j]
                                         |]
                    let nested = try dimfind <|> try (parseQuantifiedExpr nested) <|> parens nested
                    i <- nested
                    return [ [xMake| topLevel.declaration.nestedDimFind := [i]
                                   |]
                           ]
                    <?> "find statement"
                , do
                    lexeme L_where
                    xs <- parseExpr `sepEndBy1` comma
                    return [ [xMake| topLevel.where := [x] |]
                           | x <- xs ]
                    <?> "where statement"
                , do
                    lexeme L_such
                    lexeme L_that
                    xs <- parseExpr `sepEndBy1` comma
                    return [ [xMake| topLevel.suchThat := [x] |]
                           | x <- xs ]
                    <?> "such that statement"
                , do
                    lexeme L_minimising
                    x <- parseExpr
                    return [ [xMake| topLevel.objective.minimising := [x]
                                   |]
                           ]
                    <?> "objective"
                , do
                    lexeme L_maximising
                    x <- parseExpr
                    return [ [xMake| topLevel.objective.maximising := [x]
                                   |]
                           ]
                    <?> "objective"
                , do
                    lexeme L_branching
                    lexeme L_on
                    x <- parseExpr
                    return [ [xMake| topLevel.branchingOn := [x]
                                   |]
                           ]
                    <?> "branching on"
                ]
    concat <$> some one

parseLambda :: Lexeme -> Parser E
parseLambda l = do
    lexeme l
    braces $ do
        param <- parseExpr
        lexeme L_LongArrow
        body  <- parseExpr
        return [xMake| lambda.param := [param]
                     | lambda.body  := [body]
                     |]

parseQuanDecl :: Parser E
parseQuanDecl = do
    lexeme L_quantifier
    braces $ do
        append   <- parseLambda $ LIdentifier "append"
        guardE   <- parseLambda $ LIdentifier "guard"
        identity <- lexeme (LIdentifier "identity") *> parseExpr
        return [xMake| quantifierDecl.append   := [append]
                     | quantifierDecl.guard    := [guardE]
                     | quantifierDecl.identity := [identity]
                     |]


parseRange :: Parser (Range E)
parseRange = msum [try pRange, pSingle]
    where
        pRange = do
            fr <- optionMaybe parseExpr
            dot; dot
            to <- optionMaybe parseExpr
            return $ case (fr,to) of
                (Nothing, Nothing) -> RangeOpen
                (Just x , Nothing) -> RangeLowerBounded x
                (Nothing, Just y ) -> RangeUpperBounded y
                (Just x , Just y ) -> RangeBounded x y
        pSingle = do
            x <- parseExpr
            return (RangeSingle x)

parseDomain :: Parser (Domain () E)
parseDomain
    = shuntingYardDomain
    $ some
    $ msum [ Right <$> try pDomainAtom
           , Left  <$> parseOp'
           ]
    where
        parseOp' = msum [ do lexeme x; return x | x <- [L_Minus, L_union, L_intersect] ] <?> "operator"
        pDomainAtom = msum $ map try
            [ pBool, pInt, pEnum
            , pMatrix, pTupleWithout, pTupleWith
            , pSet, pMSet, pFunction, pFunction'
            , pRelation, pRelation'
            , pPartition
            , DomainHack <$> parseMetaVariable, pParens
            ]

        pParens = parens parseDomain

        pBool = do
            lexeme L_bool
            return DomainBool

        pInt = do
            lexeme L_int
            mxs <- optionMaybe $ parens $ parseRange `sepBy` comma
            let xs = fromMaybe [] mxs
            return $ DomainInt xs

        pEnum = do
            r <- identifierText
            xs <- optionMaybe $ parens $ parseRange `sepBy` comma
            case xs of
                Nothing -> return $ DomainHack [xMake| reference := [Prim (S r)] |]
                Just ys -> return $ DomainEnum (Name r) ys
                -- TODO: the DomainDefnEnum in the above line should lookup and find a
                -- previously declared DomainDefnEnum

        pMatrix = do
            lexeme L_matrix
            lexeme L_indexed
            lexeme L_by
            xs <- brackets (parseDomain `sepBy1` comma)
            lexeme L_of
            y  <- parseDomain
            return $ foldr DomainMatrix y xs

        pTupleWith = do
            lexeme L_tuple
            xs <- parens $ parseDomain `sepBy` comma
            return $ DomainTuple xs

        pTupleWithout = do
            xs <- parens $ countSepAtLeast 2 parseDomain comma
            return $ DomainTuple xs

        pSet = do
            lexeme L_set
            x <- parseSetAttr
            y <- lexeme L_of >> parseDomain
            return $ DomainSet () x y

        pMSet = do
            lexeme L_mset
            x <- parseAttributes
            y <- lexeme L_of >> parseDomain
            return $ DomainMSet () x y

        pFunction = do
            lexeme L_function
            (y,z) <- arrowedPair parseDomain
            return $ DomainFunction () (DomainAttributes []) y z

        pFunction' = do
            lexeme L_function
            x <- parseAttributes
            y <- parseDomain
            lexeme L_LongArrow
            z <- parseDomain
            return $ DomainFunction () x y z

        pRelation' = do
            lexeme L_relation
            return $ DomainHack [xMake| type.relation.inners.type.unknown := [] |]

        pRelation = do
            lexeme L_relation
            x  <- parseAttributes
            lexeme L_of
            ys <- parens (parseDomain `sepBy` lexeme L_Times)
            return $ DomainRelation () x ys

        pPartition = do
            lexeme L_partition
            x <- parseAttributes
            lexeme L_from
            y <- parseDomain
            return $ DomainPartition () x y

parseAttributes :: Parser (DomainAttributes E)
parseAttributes = do
    xs <- parens (parseAttribute `sepBy` comma) <|> return []
    return $ DomainAttributes xs
    where
        parseAttribute = msum [try parseNameValue, try parseName, parseDontCare]
        parseNameValue = DANameValue <$> (Name <$> identifierText) <*> parseExpr
        parseName = DAName <$> (Name <$> identifierText)
        parseDontCare = do dot; dot ; return DADotDot

parseSetAttr :: Parser (SetAttr E)
parseSetAttr = do
    DomainAttributes attrs <- parseAttributes
    case filter (/= DADotDot) (sort attrs) of
        [DANameValue "size"    a] -> return (SetAttrSize a)
        [DANameValue "minSize" a] -> return (SetAttrMinSize a)
        [DANameValue "maxSize" a] -> return (SetAttrMaxSize a)
        [DANameValue "maxSize" b, DANameValue "minSize" a] -> return (SetAttrMinMaxSize a b)
        [] -> return SetAttrNone
        _ -> fail ("parseSetAttr: " <+> stringToDoc (show attrs))


parseMetaVariable :: Parser E
parseMetaVariable = do
    let isMeta LMetaVar {} = True
        isMeta _           = False
    LMetaVar iden <- satisfyT isMeta
    return [xMake| metavar := [Prim (S iden)] |]

parseExpr :: Parser E
parseExpr = shuntingYardExpr parseBeforeShunt
    where
        parseBeforeShunt :: Parser [Either Lexeme E]
        parseBeforeShunt = some $ msum
            [ Right <$> try parseAtomicExpr
            , Left  <$> parseOp
            ]


parseAtomicExpr :: Parser E
parseAtomicExpr = do
    let
        prefixes = do
            fs <- some $ msum parsePrefixes
            return $ foldr1 (.) fs
        postfixes = do
            fs <- some $ msum parsePostfixes
            return $ foldr1 (.) (reverse fs)
        withPrefix  x = try x <|> do f <- prefixes; i <- x; return $ f i
        withPostfix x = do i <- x; mf <- optionMaybe postfixes; return $ case mf of Nothing -> i
                                                                                    Just f  -> f i
    withPrefix (withPostfix parseAtomicExprNoPrePost) <?> "expression"

parseAtomicExprNoPrePost :: Parser E
parseAtomicExprNoPrePost = msum $ map try
    $ parseOthers ++
    [ parseQuantifiedExpr parseExpr
    , parseMetaVariable
    , parseReference
    , parseValue
    , parseDomainAsExpr
    , parseWithLocals
    , parseMatrixComprehension
    , parens parseExpr
    ]

parseMatrixComprehension :: Parser E
parseMatrixComprehension = brackets $ do
    x <- parseExpr
    lexeme L_Bar
    gens <- some generator
    return [xMake| matrixComprehension.body       := [x]
                 | matrixComprehension.generators := gens
                 |]
    where
        generator = do
            r <- parseReference
            lexeme L_Colon
            d <- parseDomain
            return [xMake| generator.name   := [r]
                         | generator.domain := [D d]
                         |]

parseDomainAsExpr :: Parser E
parseDomainAsExpr = do
    d <- betweenTicks parseDomain
    return [xMake| domainInExpr := [D d]
                 |]

parsePrefixes :: [Parser (E -> E)]
parsePrefixes = [parseUnaryMinus, parseUnaryNot]
    where
        parseUnaryMinus = do
            lexeme L_Minus
            return $ \ x -> [xMake| unaryOp.negate := [x] |]
        parseUnaryNot = do
            lexeme L_ExclamationMark
            return $ \ x -> [xMake| unaryOp.not := [x] |]

parsePostfixes :: [Parser (E -> E)]
parsePostfixes = [parseIndexed,parseFactorial,parseFuncApply,parseReplace]
    where
        parseIndexed :: Parser (E -> E)
        parseIndexed = do
            let
                pIndexer = try pRList <|> parseExpr
                pRList   = do
                    i <- optionMaybe parseExpr
                    dot; dot
                    j <- optionMaybe parseExpr
                    return $ case (i,j) of
                        (Nothing, Nothing) -> [xMake| slicer := [] |]
                        (Just a , Nothing) -> [xMake| slicer.from := [a] |]
                        (Nothing, Just a ) -> [xMake| slicer.to   := [a] |]
                        (Just a , Just b ) -> [xMake| slicer.from := [a]
                                                    | slicer.to   := [b]
                                                    |]
            is <- brackets $ pIndexer `sepBy1` comma
            return $ \ x -> foldl (\ m' i -> [xMake| operator.index.left  := [m']
                                                   | operator.index.right := [i]
                                                   |] ) x is
        parseFactorial :: Parser (E -> E)
        parseFactorial = do
            lexeme L_ExclamationMark
            return $ \ x -> [xMake| unaryOp.factorial := [x] |]
        parseFuncApply :: Parser (E -> E)
        parseFuncApply = parens $ do
            xs <- parseExpr `sepBy1` comma
            return $ \ x -> [xMake| functionApply.actual := [x]
                                  | functionApply.args   := xs
                                  |]
        parseReplace :: Parser (E -> E)
        parseReplace = braces $ do
            let one = do
                    i <- parseExpr
                    lexeme L_LongArrow
                    j <- parseExpr
                    return (i,j)
            pairs <- one `sepBy1` comma
            return $ \ x -> foldl (\ m' (i,j) -> [xMake| operator.replace.arg1 := [m']
                                                       | operator.replace.old  := [i]
                                                       | operator.replace.new  := [j]
                                                       |] ) x pairs

parseOthers :: [Parser E]
parseOthers = [ parseFunctional l
              | l <- functionals
              ] ++ [parseTyped, parseTwoBars]
    where

        parseTwoBars :: Parser E
        parseTwoBars = do
            x <- between (lexeme L_Bar) (lexeme L_Bar) parseExpr
            return [xMake| operator.twoBars := [x] |]

        parseTyped :: Parser E
        parseTyped = parens $ do
            x <- parseExpr
            lexeme L_Colon
            y <- parseDomainAsExpr
            return [xMake| typed.left  := [x]
                         | typed.right := [y]
                         |]

        parseFunctional :: Lexeme -> Parser E
        parseFunctional l = do
            lexeme l
            xs <- parens $ parseExpr `sepBy1` comma
            return $ case (l,xs) of
                (L_image, y:ys) -> [xMake| functionApply.actual := [y]
                                         | functionApply.args   := ys
                                         |]
                _ -> Tagged "operator" [Tagged (fromString $ show $ lexemeFace l) xs]

parseWithLocals :: Parser E
parseWithLocals = braces $ do
    i  <- parseExpr
    lexeme L_At
    js <- parseTopLevels
    return [xMake| withLocals.actual := [i]
                 | withLocals.locals := js
                 |]

parseReference :: Parser E
parseReference = do
    x <- identifierText
    return [xMake| reference := [Prim (S x)]
                 |]


parseOp :: Parser Lexeme
parseOp = msum [ do lexeme x; return x | (x,_,_) <- operators ]
    <?> "operator"

parseQuantifiedExpr :: Parser E -> Parser E
parseQuantifiedExpr parseBody = do
        let pOp = msum [ [xMake| binOp.subset   := [] |] <$ lexeme L_subset
                       , [xMake| binOp.subsetEq := [] |] <$ lexeme L_subsetEq
                       , [xMake| binOp.in       := [] |] <$ lexeme L_in
                       ]
        qnName   <- parseMetaVariable <|> parseReference
        qnVars   <- parseStructural `sepBy1` comma
        qnDom    <- optionMaybe (colon *> parseDomain)
        qnExpr   <- optionMaybe ((,) <$> pOp <*> parseExpr)
        case (qnDom,qnExpr) of
            (Nothing, Nothing) -> fail "expecting something to quantify over"
            _ -> return ()
        qnGuard <- optionMaybe (comma *> parseExpr)
        qnBody  <- dot *> parseBody <?> "expecting body of a quantified expression"

        let emptyGuard = [ [xMake| emptyGuard := [] |] ]

        let
            singleStructurals = [ i | [xMatch| [i] := structural.single |] <- concatMap universe qnVars ]

            idenToSingleStructural i | i `elem` singleStructurals = [xMake| structural.single := [i] |]
            idenToSingleStructural (Tagged t xs) = Tagged t $ map idenToSingleStructural xs
            idenToSingleStructural i = i

        let
            fixedQuanDoms  = map idenToSingleStructural $ case qnDom  of Just a     -> [D a]; _ -> []
            fixedQuanOps   = map idenToSingleStructural $ case qnExpr of Just (a,_) -> [a]; _ -> []
            fixedQuanExprs = map idenToSingleStructural $ case qnExpr of Just (_,a) -> [a]; _ -> []
            fixedGuards    = map idenToSingleStructural $ case qnGuard of Nothing -> emptyGuard ; Just g  -> [g]
            fixedBodys     = map idenToSingleStructural [qnBody]

        let
            f []     = bug "The Impossible has happenned. in parseQuantifiedExpr.f"
            f [i]    = [xMake| quantified.quantifier   := [qnName]
                             | quantified.quanVar      := [i]
                             | quantified.quanOverDom  := fixedQuanDoms
                             | quantified.quanOverOp   := fixedQuanOps
                             | quantified.quanOverExpr := fixedQuanExprs
                             | quantified.guard        := fixedGuards
                             | quantified.body         := fixedBodys
                             |]
            f (i:is) = [xMake| quantified.quantifier   := [qnName]
                             | quantified.quanVar      := [i]
                             | quantified.quanOverDom  := fixedQuanDoms
                             | quantified.quanOverOp   := fixedQuanOps
                             | quantified.quanOverExpr := fixedQuanExprs
                             | quantified.guard        := emptyGuard
                             | quantified.body         := [f is]
                             |]
        return $ f qnVars

parseStructural :: Parser E
parseStructural = msum
    [ parseMetaVariable
    , do
        x <- parseReference
        return [xMake| structural.single := [x] |]
    , do
        void $ optionMaybe $ lexeme L_tuple
        xs <- parens $ parseStructural `sepBy1` comma
        return [xMake| structural.tuple := xs |]
    , do
        xs <- brackets $ parseStructural `sepBy1` comma
        return [xMake| structural.matrix := xs |]
    , do
        xs <- braces $ parseStructural `sepBy1` comma
        return [xMake| structural.set := xs |]
    ]

parseValue :: Parser E
parseValue = msum ( map try
    [ pBool, pInt
    , pMatrix, pMatrix', pTupleWith, pTupleWithout
    , pSet, pMSet
    , pFunction, pRelation, pPartition
    ] ) <?> "value"
    where
        pBool = do
            x <- Prim (B False) <$ lexeme L_false
                 <|>
                 Prim (B True)  <$ lexeme L_true
            return [xMake| value.literal := [x] |]

        pInt = do
            x <- Prim . I <$> integer
            return [xMake| value.literal := [x] |]

        pMatrix = do
            xs <- brackets (sepBy parseExpr comma)
            return [xMake| value.matrix.values := xs |]

        pMatrix' = brackets $ do
            xs <- sepBy parseExpr comma
            lexeme L_SemiColon
            r <- parseDomain
            return [xMake| value.matrix.values     := xs
                         | value.matrix.indexrange := [D r]
                         |]
        pTupleWith = do
            lexeme L_tuple
            xs <- parens $ sepBy parseExpr comma
            return [xMake| value.tuple.values := xs |]

        pTupleWithout = do
            xs <- parens $ countSepAtLeast 2 parseExpr comma
            return [xMake| value.tuple.values := xs |]

        pSet = do
            xs <- braces (sepBy parseExpr comma)
            return [xMake| value.set.values := xs |]

        pMSet = do
            lexeme L_mset
            xs <- parens (sepBy parseExpr comma)
            return [xMake| value.mset.values := xs |]

        pFunction = do
            lexeme L_function
            xs <- parens (sepBy inner comma)
            return [xMake| value.function.values := xs |]
            where
                inner = do
                    (i,j) <- arrowedPair parseExpr
                    return [xMake| mapping := [i,j] |]

        pRelation = do
            lexeme L_relation
            xs <- parens (sepBy (try pTupleWith <|> pTupleWithout) comma)
            return [xMake| value.relation.values := xs |]

        pPartition = do
            lexeme L_partition
            xs <- parens (sepBy inner comma)
            return [xMake| value.partition.values := xs|]
            where
                inner = do
                    is <- braces (sepBy parseExpr comma)
                    return [xMake| part := is |]

shuntingYardExpr :: Parser [Either Lexeme E] -> Parser E
shuntingYardExpr p = do
    let mergeOp op before after =
            [xMake| binOp.operator := [Prim (S $ lexemeText op)]
                  | binOp.left     := [before]
                  | binOp.right    := [after]
                  |]
    beforeShunt <- fixNegate <$> p
    if not $ checkAlternating beforeShunt
        then fail "Malformed expression, Shunting Yard failed."
        else shunt mergeOp beforeShunt

shuntingYardDomain :: Eq a => Parser [Either Lexeme (Domain () a)] -> Parser (Domain () a)
shuntingYardDomain p = do
    let mergeOp op before after = DomainOp (Name (lexemeText op)) [before,after]
    beforeShunt <- p
    if not $ checkAlternating beforeShunt
        then fail "Malformed expression, Shunting Yard failed."
        else shunt mergeOp beforeShunt

fixNegate :: [Either Lexeme E] -> [Either Lexeme E]
fixNegate ( Right a
          : Right ([xMatch| [b] := unaryOp.negate |])
          : cs
          ) = fixNegate $ Right a : Left L_Minus : Right b : cs
fixNegate (a:bs) = a : fixNegate bs
fixNegate [] = []

checkAlternating :: [Either a b] -> Bool
checkAlternating [Right _] = True
checkAlternating (Right _:Left _:rest) = checkAlternating rest
checkAlternating _ = False

shunt :: Eq a => (Lexeme -> a -> a -> a) -> [Either Lexeme a] -> Parser a
shunt mergeOp xs = do
    result <- findPivotOp xs
    case result of
        Left x -> return x
        Right (before, op, after) -> do
            b <- shunt mergeOp before
            a <- shunt mergeOp after
            return (mergeOp op b a)

findPivotOp :: Eq a => [Either Lexeme a] -> Parser (Either a ([Either Lexeme a], Lexeme, [Either Lexeme a]))
findPivotOp [Right x] = return $ Left x
findPivotOp xs = do
    let
        pivotPrec :: Int
        pivotFixity :: Fixity
        (pivotPrec,pivotFixity) = minimumBy (comparing fst)
                        [ (p, f) | Left l <- xs, (l',f,p) <- operators, l == l' ]

        chck op = case [ p | (l,_,p) <- operators, l == op ] of
                    [p] -> p == pivotPrec
                    _ -> False

        findFirst :: Eq a => [Either Lexeme a] -> Parser ([Either Lexeme a], Lexeme, [Either Lexeme a])
        findFirst [] = fail "findPivotOp.findFirst"
        findFirst (Left i:is) | chck i = return ([], i, is)
        findFirst (i:is) = do
            (before, op, after) <- findFirst is
            return (i:before, op, after)

        findLast :: Eq a => [Either Lexeme a] -> Parser ([Either Lexeme a], Lexeme, [Either Lexeme a])
        findLast is = do
            (before, op, after) <- findFirst (reverse is)
            return (reverse after, op, reverse before)

        findOnly :: Eq a => [Either Lexeme a] -> Parser ([Either Lexeme a], Lexeme, [Either Lexeme a])
        findOnly is = do
            f <- findFirst is
            l <- findLast  is
            if f == l
                then return f
                else fail "Ambiguous use of non-associative operator."

    let
        finder = case pivotFixity of
                    FLeft  -> findLast
                    FNone  -> findOnly
                    FRight -> findFirst
    Right <$> finder xs





type Parser a = ParsecT [LexemePos] () Identity a

_testParsePrint' :: Parser E -> T.Text -> IO ()
_testParsePrint' p t = do
    let res = runLexerAndParser p "" t
    case res of
        Left  e -> print e
        Right x -> do
            -- print x
            -- print $ prettyAsTree x
            print $ prettyAsPaths x
            print $ pretty x

_testParsePrint'' :: Parser [E] -> T.Text -> IO ()
_testParsePrint'' p t = do
    let res = runLexerAndParser p "" t
    case res of
        Left  e  -> print e
        Right xs -> forM_ xs $ \ x -> do
            -- print x
            -- print $ prettyAsTree x
            print $ prettyAsPaths x
            print $ pretty x

runLexerAndParser :: (MonadError Pr.Doc m, Applicative m) => Parser a -> String -> T.Text -> m a
runLexerAndParser p s = runLexer >=> runParser p s

runParser :: (MonadError Pr.Doc m) => Parser a -> String -> [LexemePos] -> m a
runParser p s ls =
    -- error $ unlines $ map show ls
    case parse p s ls of
        Left  e -> let eDoc = pretty $ show e
                   in  throwError $ pretty s <+> eDoc
        Right x -> return x

identifierText :: Parser T.Text
identifierText = do
    LIdentifier i <- satisfyT isIdentifier
    return i
    where isIdentifier LIdentifier {} = True
          isIdentifier _ = False

satisfyT :: (Lexeme -> Bool) -> Parser Lexeme
satisfyT predicate = tokenPrim showTok nextPos testTok
    where
        showTok              = show . lexemeFace . fst
        testTok (tok, _)     = if predicate tok then Just tok else Nothing
        nextPos _ (_, pos) _ = pos

integer :: Parser Integer
integer = do
    LIntLiteral i <- satisfyT isInt
    return i
    where isInt LIntLiteral {} = True
          isInt _ = False

comma :: Parser ()
comma = lexeme L_Comma <?> "comma"

dot :: Parser ()
dot = lexeme L_Dot <?> "dot"

colon :: Parser ()
colon = lexeme L_Colon <?> "colon"


-- parses a specified number of elements separated by the given separator
countSep :: Int -> Parser a -> Parser sep -> Parser [a]
countSep 1 p _ = (:[]) <$> p
countSep i p separator | i > 1 = (:) <$> (p <* separator) <*> countSep (i-1) p separator
countSep _ _ _ = return []

-- parses at least a given number of elements separated by the given separator
countSepAtLeast :: Int -> Parser a -> Parser sep -> Parser [a]
countSepAtLeast i p separator = (++) <$> countSep i p separator <*> many (separator *> p)

betweenTicks :: Parser a -> Parser a
betweenTicks = between (lexeme L_BackTick) (lexeme L_BackTick)

parens :: Parser a -> Parser a
parens = between (lexeme L_OpenParen) (lexeme L_CloseParen)

braces :: Parser a -> Parser a
braces = between (lexeme L_OpenCurly) (lexeme L_CloseCurly)

brackets :: Parser a -> Parser a
brackets = between (lexeme L_OpenBracket) (lexeme L_CloseBracket)

lexeme :: Lexeme -> Parser ()
lexeme l = void (satisfyT (l==)) <?> show (lexemeFace l)

arrowedPair :: Parser a -> Parser (a,a)
arrowedPair p = do
    i <- p
    lexeme L_LongArrow
    j <- p
    return (i,j)

inCompleteFile :: Parser a -> Parser a
inCompleteFile parser = do
    result <- parser
    eof
    return result
