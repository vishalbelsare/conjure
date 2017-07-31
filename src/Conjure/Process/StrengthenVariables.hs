{-
 - Module      : Conjure.Process.StrengthenVariables
 - Description : Strengthen variables using type- and domain-inference.
 - Copyright   : Billy Brown 2017
 - License     : BSD3
 
 Processing step that attempts to strengthen variables at the Essence class level, using methods described in the "Reformulating Essence Specifications for Robustness" paper.
-}

{-# LANGUAGE QuasiQuotes #-}

module Conjure.Process.StrengthenVariables
  (
    strengthenVariables
  ) where

import Data.List ( find, union )
-- import Data.Map.Strict ( Map )
-- import qualified Data.Map.Strict as M ( (!?), empty, union )
import Data.Maybe ( mapMaybe )

import Conjure.Prelude
import Conjure.Language
import Conjure.Language.Domain.AddAttributes
import Conjure.Language.NameResolution ( resolveNames )
-- These two are needed together
import Conjure.Language.Expression.DomainSizeOf ()
import Conjure.Language.DomainSizeOf ( domainSizeOf )
import Conjure.Compute.DomainOf ( domainOf )
-- import Conjure.UI.VarSymBreaking ( outputVarSymBreaking )

-- -- aeson
-- import qualified Data.Aeson as JSON ( decodeStrict )
-- -- shelly
-- import Shelly ( run, shelly, silently )
-- -- directory
-- import System.Directory ( removeFile )
-- -- text
-- import qualified Data.Text.Encoding as T ( encodeUtf8 )
-- uniplate zipper
import Data.Generics.Uniplate.Zipper ( Zipper, zipper, down, fromZipper, hole, replaceHole, right, up )

type ExpressionZ = Zipper Expression Expression
type FindVar = (Name, Domain () Expression)
type AttrPair = (AttrName, Maybe Expression)
type ToAddToRem = ([ExpressionZ], [ExpressionZ])

-- | Strengthen the variables in a model using type- and domain-inference.
strengthenVariables :: (MonadFail m, MonadIO m, MonadLog m, MonadUserError m)
                    => Model -> m Model
strengthenVariables = runNameGen . (resolveNames >=> core . fixRelationProj)
  where
    core :: (MonadFail m, MonadIO m, MonadLog m, MonadUserError m, NameGen m) => Model -> m Model
    core model = do
      -- Apply rules to each decision (find) variable
      (model', toAddToRem) <- foldM (\modelAndToKeep findAndCstrs ->
          -- Apply each rule to the variable and hold on to constraints to keep
          foldM (\(m, tatr) rule -> do
                  (attrs, tatr') <- nested rule m findAndCstrs
                  let m' = foldr (uncurry3 addAttrsToModel) m attrs
                  return (m', toAddRem tatr' tatr))
                modelAndToKeep [ varSize
                               , surjectiveIsTotalBijective
                               , totalInjectiveIsBijective
                               , definedForAllIsTotal
                               , diffArgResultIsInjective
                               , setSize
                               , mSetSizeOccur
                               , mSetOccur
                               , funcRangeEqSet
                               ])
          (model, ([], []))
          (zip (collectFindVariables model)
               (repeat $ map zipper $ collectConstraints model))
      let model'' = addConstraints (fst toAddToRem) $
                    remConstraints (snd toAddToRem) model'
      -- Make another pass if the model was updated
      if model == model''
         then return model''
         else core model''

-- | 'uncurry' for functions of three arguments and triples.
uncurry3 :: (a -> b -> c -> d) -> ((a, b, c) -> d)
uncurry3 f (x, y, z) = f x y z

-- | Collect decision (find) variables from a model, returning their name and domain.
collectFindVariables :: Model -> [FindVar]
collectFindVariables = mapMaybe collectFind . mStatements
  where
    collectFind (Declaration (FindOrGiven Find n d)) = Just (n, d)
    collectFind _                                    = Nothing

-- | Collect the constraints in a model.
collectConstraints :: Model -> [Expression]
collectConstraints = concatMap getSuchThat . mStatements
  where
    getSuchThat (SuchThat cs) = cs
    getSuchThat _             = []

-- | Add constraints to a model.
addConstraints :: [ExpressionZ] -> Model -> Model
addConstraints [] m = m
addConstraints cs m@Model { mStatements = stmts }
  = m { mStatements = addConstraints' stmts }
  where
    addConstraints' (SuchThat cs':ss) = SuchThat (cs' `union` map fromZipper cs) : ss
    addConstraints' (s:ss)            = s : addConstraints' ss
    addConstraints' []                = [SuchThat (map fromZipper cs)]

-- | Remove a list of constraints from a model.
remConstraints :: [ExpressionZ] -> Model -> Model
remConstraints cs m@Model { mStatements = stmts }
  = m { mStatements = filter (not . emptySuchThat) $ map remConstraints' stmts }
  where
    remConstraints' (SuchThat cs') = SuchThat $ filter (`notElem` map fromZipper cs) cs'
    remConstraints' s              = s
    emptySuchThat (SuchThat []) = True
    emptySuchThat _             = False

-- | Update the domain of a declaration in a model.
updateDecl :: FindVar -> Model -> Model
updateDecl (n, d) m@Model { mStatements = stmts } = m { mStatements = map updateDecl' stmts }
  where
    updateDecl' (Declaration (FindOrGiven Find n' _))
      | n == n' = Declaration (FindOrGiven Find n d)
    updateDecl' decl = decl

-- | Try adding an attribute at a given depth of a variable's domain, in a model.
addAttrsToModel :: FindVar -> Int -> [AttrPair] -> Model -> Model
addAttrsToModel (n, _) depth attrs m
  = let d = snd <$> find (\(n', _) -> n == n') (collectFindVariables m)
        in case d >>= flip (addAttrsToDomain depth) attrs of
                Just d' -> updateDecl (n, d') m
                Nothing -> m
  where
    addAttrsToDomain :: (MonadFail m) => Int -> Domain () Expression -> [AttrPair] -> m (Domain () Expression)
    addAttrsToDomain 0 dom = addAttributesToDomain dom . map mkAttr
    addAttrsToDomain level (DomainSet r as inner)           = addAttrsToDomain (level - 1) inner >=> (pure . DomainSet r as)
    addAttrsToDomain level (DomainMSet r as inner)          = addAttrsToDomain (level - 1) inner >=> (pure . DomainMSet r as)
    addAttrsToDomain level (DomainMatrix index inner)       = addAttrsToDomain (level - 1) inner >=> (pure . DomainMatrix index)
    addAttrsToDomain level (DomainFunction r as from inner) = addAttrsToDomain (level - 1) inner >=> (pure . DomainFunction r as from)
    addAttrsToDomain level (DomainPartition r as inner)     = addAttrsToDomain (level - 1) inner >=> (pure . DomainPartition r as)
    addAttrsToDomain _ _ = const (fail "[addAttrsToDomain] not a supported nested domain")
    -- Special treatment for functions
    mkAttr (attr, Just [essence| image(&f, &_) |])     = (attr, Just [essence| max(range(&f)) |])
    mkAttr (attr, Just [essence| image(&f, &_) - 1 |]) = (attr, Just [essence| max(range(&f)) - 1 |])
    mkAttr (attr, Just [essence| image(&f, &_) + 1 |]) = (attr, Just [essence| max(range(&f)) + 1 |])
    mkAttr (attr, e')                                  = (attr, e')

-- | Does an expression directly reference a given name variable?
nameExpEq :: Name -> Expression -> Bool
nameExpEq n (Reference n' _)           = n == n'
nameExpEq n [essence| image(&f, &x) |] = nameExpEq n f || nameExpEq n x
nameExpEq n [essence| &f(&x) |]        = nameExpEq n f || nameExpEq n x
nameExpEq n [essence| defined(&f) |]   = nameExpEq n f
nameExpEq n [essence| range(&f) |]     = nameExpEq n f
nameExpEq _ _                          = False

-- | Does a reference refer to an abstract pattern?
refersTo :: AbstractPattern -> Expression -> Bool
refersTo a (Reference n _) = n `elem` namesFromAbstractPattern a
refersTo _ _               = False

-- | Get a single name from an abstract pattern.
nameFromAbstractPattern :: (MonadFail m) => AbstractPattern -> m Name
nameFromAbstractPattern a = case namesFromAbstractPattern a of
                                 [n] -> pure n
                                 []  -> fail "[nameFromAbstractPattern] no names in abstract pattern"
                                 _   -> fail "[nameFromAbstractPattern] more than one name in abstract pattern"

-- | Get the list of names from an abstract pattern.
namesFromAbstractPattern :: AbstractPattern -> [Name]
namesFromAbstractPattern (Single n)        = [n]
namesFromAbstractPattern (AbsPatTuple ns)  = concatMap namesFromAbstractPattern ns
namesFromAbstractPattern (AbsPatMatrix ns) = concatMap namesFromAbstractPattern ns
namesFromAbstractPattern (AbsPatSet ns)    = concatMap namesFromAbstractPattern ns
namesFromAbstractPattern _                 = []

-- | Find an expression at any depth of unconditional forAll expressions.
findInUncondForAll :: (Expression -> Bool) -> [ExpressionZ] -> [Expression]
findInUncondForAll p = map hole . findInUncondForAllZ p

-- | Find an expression at any depth of unconditional forAll expressions,
--   returning a Zipper containing the expression's context.
findInUncondForAllZ :: (Expression -> Bool) -> [ExpressionZ] -> [ExpressionZ]
findInUncondForAllZ p = concatMap findInForAll
  where
    findInForAll z | p (hole z) = [z]
    findInForAll z
      = case hole z of
             [essence| forAll &x, &y : &_, &x' != &y' . &_ |]
               | refersTo x x' && refersTo y y'
                 -> maybe [] findInForAll (down z >>= down)
             [essence| forAll &x, &y in &_, &x' != &y' . &_ |]
               | refersTo x x' && refersTo y y'
                 -> maybe [] findInForAll (down z >>= down)
             Op (MkOpAnd (OpAnd (Comprehension _ gorcs)))
               | all (not . isCondition) gorcs
                 -> maybe [] findInForAll (down z >>= down)
             [essence| &_ /\ &_ |]
                 -> maybe [] findInForAll (down z)
                    `union`
                    maybe [] findInForAll (right z >>= down)
             -- Only accept OR cases if both sides contain a match
             [essence| &_ \/ &_ |]
                 -> let leftResult  = maybe [] findInForAll (down z)
                        rightResult = maybe [] findInForAll (right z >>= down)
                        in if not (null leftResult) && not (null rightResult)
                              then leftResult `union` rightResult
                              else []
             _   -> []
    isCondition Condition{} = True
    isCondition _           = False

-- | Unzip where the key is a 'Maybe' but the values should all be combined.
unzipMaybeK :: Monoid m => [(Maybe a, m)] -> ([a], m)
unzipMaybeK = foldr (\(mx, y) (xs, z) ->
                     case mx of
                          Just x  -> (x:xs, y `mappend` z)
                          Nothing -> (  xs, y `mappend` z))
              ([], mempty)

-- | Add expressions to the ToAdd list.
toAdd :: [ExpressionZ] -> ToAddToRem -> ToAddToRem
toAdd e = first (`union` e)

-- | Add expressions to the ToRemove list.
toRem :: [ExpressionZ] -> ToAddToRem -> ToAddToRem
toRem e = second (`union` e)

-- | Combine two 'ToAddToRem' values.
toAddRem :: ToAddToRem -> ToAddToRem -> ToAddToRem
toAddRem (ta, tr) = toAdd ta . toRem tr

-- | Apply a rule to arbitrary levels of nested domains.
nested :: (MonadFail m, MonadLog m, NameGen m)
       => (Model -> (FindVar, [ExpressionZ])
                 -> m ([AttrPair], ToAddToRem))
       -> Model
       -> (FindVar, [ExpressionZ])
       -> m ([(FindVar, Int, [AttrPair])], ToAddToRem)
nested rule m fc@(fv, cs) = do
  -- Apply the rule at the top level
  (attrs, toAddToRem) <- rule m fc
  -- Look deeper into the domain if possible, for forAll constraints involving it
  nestedResults <- fmap mconcat $ forM cs $ \c ->
    case hole c of
         [essence| forAll &x in &gen . &_ |] | nameExpEq (fst fv) gen -> do
           -- Create the new decision variable at this level
           fv' <- (,) <$> nameFromAbstractPattern x
                      <*> (domainOf gen >>= innerDomainOf)
           -- Apply the rule from here
           out <- nested rule m (fv', mapMaybe (down >=> down) [c])
           case out of
                ([], _)     -> return mempty
                -- The rule was applied, so unwrap the variable and increase the depth
                (vs, tatr') -> return ( [ (fv, d + 1, as) | (_, d, as) <- vs ]
                                      , tatr')
         _ -> return mempty
  -- Do not add a modification if there are no attributes
  let attrs' = if null attrs then [] else [(fv, 0, attrs)]
  return $ mappend nestedResults (attrs', toAddToRem)

-- | Set a size attribute on a variable.
varSize :: (MonadFail m, MonadLog m)
        => Model
        -> (FindVar, [ExpressionZ])
        -> m ([AttrPair], ToAddToRem)
varSize _ ((n, _), cs) = do
  results <- forM cs $ \c ->
    case hole c of
         [essence| |&x| =  &e |] | nameExpEq n x -> pure (Just ("size",    Just e),       ([], [c]))
         [essence| |&x| <  &e |] | nameExpEq n x -> pure (Just ("maxSize", Just $ e - 1), ([], [c]))
         [essence| |&x| <= &e |] | nameExpEq n x -> pure (Just ("maxSize", Just e),       ([], [c]))
         [essence| |&x| >  &e |] | nameExpEq n x -> pure (Just ("minSize", Just $ e + 1), ([], [c]))
         [essence| |&x| >= &e |] | nameExpEq n x -> pure (Just ("minSize", Just e),       ([], [c]))
         _                                       -> pure (Nothing, mempty)
  return $ unzipMaybeK results

-- | If a function is surjective or bijective, and its domain and codomain
--   are of equal size, then it is total and bijective.
surjectiveIsTotalBijective :: (MonadFail m, MonadLog m)
                           => Model
                           -> (FindVar, [ExpressionZ])
                           -> m ([AttrPair], ToAddToRem)
surjectiveIsTotalBijective _ ((_, dom), _)
  = case dom of
         DomainFunction _ (FunctionAttr _ p j) from to
           | (p == PartialityAttr_Partial && j == JectivityAttr_Bijective) ||
             j == JectivityAttr_Surjective -> do
               (fromSize, toSize) <- functionDomainSizes from to
               if fromSize == toSize
                  then return ([("total", Nothing), ("bijective", Nothing)], mempty)
                  else return mempty
         _ -> return mempty

-- | Calculate the sizes of the domain and codomain of a function.
functionDomainSizes :: (MonadFail m)
                    => Domain () Expression       -- ^ The function's domain.
                    -> Domain () Expression       -- ^ The function's codomain.
                    -> m (Expression, Expression) -- ^ The sizes of the two.
functionDomainSizes from to = (,) <$> domainSizeOf from <*> domainSizeOf to

-- | If a function is total and injective, and its domain and codomain
--   are of equal size, then it is bijective.
totalInjectiveIsBijective :: (MonadFail m, MonadLog m)
                          => Model
                          -> (FindVar, [ExpressionZ])
                          -> m ([AttrPair], ToAddToRem)
totalInjectiveIsBijective _ ((_, dom), _)
  = case dom of
         DomainFunction _ (FunctionAttr _ PartialityAttr_Total JectivityAttr_Injective) from to -> do
           (fromSize, toSize) <- functionDomainSizes from to
           if fromSize == toSize
              then return ([("bijective", Nothing)], mempty)
              else return mempty
         _ -> return mempty

-- | If a function is defined for all values in its domain, then it is total.
definedForAllIsTotal :: (MonadFail m, MonadLog m)
                     => Model
                     -> (FindVar, [ExpressionZ])
                     -> m ([AttrPair], ToAddToRem)
definedForAllIsTotal _ ((n, dom), cs)
  -- Is the function called with parameters generated from its domain in an expression?
  = let definedIn from e = any (funcCalledWithGenParams from) (children e)
        in case dom of
                DomainFunction _ (FunctionAttr _ PartialityAttr_Partial _) from _
                  | any (definedIn from) $ findInUncondForAll isOp cs
                    -> return ([("total", Nothing)], mempty)
                _ -> return mempty
  where
    -- Look for operator expressions but leave comprehensions, and ORs up to findInUncondForAll
    isOp (Op (MkOpAnd (OpAnd Comprehension{}))) = False
    isOp [essence| &_ \/ &_ |]                  = False
    -- Disallow implications which may remove some cases
    isOp [essence| &_ -> &_ |]                  = False
    isOp Op{}                                   = True
    isOp _                                      = False
    -- Determine whether a function is called with values generated from its domain
    funcCalledWithGenParams d [essence| image(&f, &param) |]
      = nameExpEq n f && case domainOf param of
                              Right d' -> d' == d
                              Left _   -> False
    funcCalledWithGenParams _ _ = False

-- | If all distinct inputs to a function have distinct results, then it is injective.
--   It will also be total if there are no conditions other than the disequality between
--   the two inputs.
diffArgResultIsInjective :: (MonadFail m, MonadLog m)
                         => Model
                         -> (FindVar, [ExpressionZ])
                         -> m ([AttrPair], ToAddToRem)
diffArgResultIsInjective _ ((n, DomainFunction _ (FunctionAttr _ _ ject) from _), cs)
  | (ject == JectivityAttr_None || ject == JectivityAttr_Surjective) &&
    not (null $ findInUncondForAll isDistinctDisequality cs)
    -- It is known that no inputs are ignored
    = return ([("injective", Nothing), ("total", Nothing)], mempty)
  where
    -- Match a very specific pattern, which will also add the total attribute
    isDistinctDisequality [essence| &i != &j -> image(&f, &i') != image(&f', &j') |]
      = f == f' && i == i' && j == j' &&
        nameExpEq n f &&          -- the function is the one under consideration
        domIsGen i && domIsGen j  -- the values are generated from the function's domain
    isDistinctDisequality _ = False
    domIsGen x = case domainOf x of
                      Right dom -> dom == from
                      Left _    -> False
diffArgResultIsInjective _ _ = return mempty

-- | Set the minimum size of a set based on it being a superset of another.
setSize :: (MonadFail m, MonadLog m, NameGen m)
        => Model
        -> (FindVar, [ExpressionZ])
        -> m ([AttrPair], ToAddToRem)
setSize _ ((n, DomainSet{}), cs)
  = fmap mconcat $ forM cs $ \c ->
    case hole c of
         -- subset(Eq)
         [essence| &l subset   &r |] | nameExpEq n r -> return (minSize l (+ 1), mempty)
         [essence| &l subset   &r |] | nameExpEq n l -> return (maxSize r (\x -> x - 1), mempty)
         [essence| &l subsetEq &r |] | nameExpEq n r -> return (minSize l id, mempty)
         [essence| &l subsetEq &r |] | nameExpEq n l -> return (maxSize r id, mempty)
         -- supset(Eq)
         [essence| &l supset   &r |] | nameExpEq n l -> return (minSize r (+ 1), mempty)
         [essence| &l supset   &r |] | nameExpEq n r -> return (maxSize l (\x -> x - 1), mempty)
         [essence| &l supsetEq &r |] | nameExpEq n l -> return (minSize r id, mempty)
         [essence| &l supsetEq &r |] | nameExpEq n r -> return (maxSize l id, mempty)
         _                                           -> return mempty
  where
    minSize [essence| defined(&g) |] f
      = case domainOf g of
             Right (DomainFunction _ (FunctionAttr _ PartialityAttr_Total _) from _) ->
               case domainSizeOf from of
                    Just s  -> [("minSize", Just (f s))]
                    Nothing -> mempty
             _ -> mempty
    minSize [essence| range(&g) |] f
      = case domainOf g of
             Right (DomainFunction _ (FunctionAttr _ PartialityAttr_Total _) _ to) ->
               case domainSizeOf to of
                    Just s  -> [("minSize", Just (f s))]
                    Nothing -> mempty
             _ -> mempty
    minSize e f = case domainOf e of
                       Right (DomainSet _ (SetAttr (SizeAttr_Size mn)) _) ->
                         [("minSize", Just (f mn))]
                       Right (DomainSet _ (SetAttr (SizeAttr_MinSize mn)) _) ->
                         [("minSize", Just (f mn))]
                       Right (DomainSet _ (SetAttr (SizeAttr_MinMaxSize mn _)) _) ->
                         [("minSize", Just (f mn))]
                       _ -> mempty
                       -- TODO: extend for Matrix, MSet, Partition and Sequence
    maxSize [essence| defined(&g) |] f
      = case domainOf g >>= innerDomainOf of
             Right (DomainTuple [d, _]) ->
               case domainSizeOf d of
                    Just s  -> [("maxSize", Just (f s))]
                    Nothing -> mempty
             _ -> mempty
    maxSize [essence| range(&g) |] f
      = case domainOf g >>= innerDomainOf of
             Right (DomainTuple [_, d]) ->
               case domainSizeOf d of
                    Just s  -> [("maxSize", Just (f s))]
                    Nothing -> mempty
             _ -> mempty
    maxSize e f = case domainOf e of
                       Right (DomainSet _ (SetAttr (SizeAttr_Size mx)) _) ->
                         [("maxSize", Just (f mx))]
                       Right (DomainSet _ (SetAttr (SizeAttr_MaxSize mx)) _) ->
                         [("maxSize", Just (f mx))]
                       Right (DomainSet _ (SetAttr (SizeAttr_MinMaxSize _ mx)) _) ->
                         [("maxSize", Just (f mx))]
                       Right d@(DomainSet _ (SetAttr SizeAttr_None) _) ->
                         case domainSizeOf d of
                              Just mx -> [("maxSize", Just (f mx))]
                              Nothing -> mempty
                       _ -> mempty
                       -- TODO: extend for Matrix, MSet, Partition and Sequence
setSize _ _ = return mempty

-- | The maxSize, and minOccur attributes of an mset affect its maxOccur and minSize attributes.
mSetSizeOccur :: (MonadFail m, MonadLog m)
              => Model
              -> (FindVar, [ExpressionZ])
              -> m ([AttrPair], ToAddToRem)
mSetSizeOccur _ ((_, d), _)
  = case d of
         -- Ordering is important here, as there is a rule that applies
         -- to maxSize and minOccur, but none that applies to minSize
         -- and maxOccur. size uses the maxSize rule, but can ignore a
         -- minOccur because it cannot have its minSize changed.
         -- size -> maxOccur
         DomainMSet _ (MSetAttr (SizeAttr_Size mx) _) _
           -> return ([("maxOccur", Just mx)], mempty)
         -- minOccur -> minSize
         DomainMSet _ (MSetAttr _ (OccurAttr_MinOccur mn)) _
           -> return ([("minSize", Just mn)], mempty)
         DomainMSet _ (MSetAttr _ (OccurAttr_MinMaxOccur mn _)) _
           -> return ([("minSize", Just mn)], mempty)
         -- maxSize -> maxOccur
         DomainMSet _ (MSetAttr (SizeAttr_MaxSize mx) _) _
           -> return ([("maxOccur", Just mx)], mempty)
         DomainMSet _ (MSetAttr (SizeAttr_MinMaxSize _ mx) _) _
           -> return ([("maxOccur", Just mx)], mempty)
         _ -> return mempty

-- | Infer multiset occurrence attributes from constraints.
mSetOccur :: (MonadFail m, MonadLog m)
          => Model
          -> (FindVar, [ExpressionZ])
          -> m ([AttrPair], ToAddToRem)
mSetOccur _ ((n, DomainMSet _ _ d), cs)
  = return $ mconcat $ flip mapMaybe (findInUncondForAllZ (not . null . isFreq) cs) $ \e ->
      case isFreq (hole e) of
           [] -> Nothing
           -- Only remove constraints if they are all used up.
           -- Because freq(a, b) = c adds two attributes, removing constraints
           -- in an AND expression cannot work, in the case of freq(a, b) = c /\ e
           -- because there are two attributes and two terms, but term e may not
           -- be removed.
           as -> let tattr = case hole e of
                                  AbstractLiteral AbsLitMatrix{} -> mempty
                                  _                              -> ([], [e])
                     in Just (as, tattr)
  where
    isFreq :: Expression -> [AttrPair]
    isFreq (AbstractLiteral (AbsLitMatrix _ es)) = concatMap isFreq es
    isFreq e = case matching e oppIneqOps of
                    Just (_, ([essence| freq(&x, &v) |], e'))
                      | valid x v e' -> case matching e ineqOccurAttrs of
                                             Just (as, _) -> map (second ($ e')) as
                                             Nothing      -> []
                    -- Flip the terms
                    Just (oper, (l, r@[essence| freq(&x, &v) |]))
                      | valid x v l -> isFreq $ make oper r l
                    _               -> []
    -- Make sure that the expression's components are valid
    valid :: Expression -> Expression -> Expression -> Bool
    valid x v e = nameExpEq n x && isGen v && isConst e
    -- Make sure that the value is generated from the mset's domain
    isGen (Reference _ (Just (DeclNoRepr Quantified _ d' _))) = d == d'
    isGen _ = False
    -- Make sure that the mset is being equated to a constant
    isConst (Constant ConstantInt{}) = True
    isConst _ = False
mSetOccur _ _ = return mempty

-- | Equate the range of a function to a set of the former is a subset of the latter
--   and all values in the set are results of the function.
funcRangeEqSet :: (MonadFail m, MonadLog m)
               => Model
               -> (FindVar, [ExpressionZ])
               -> m ([AttrPair], ToAddToRem)
funcRangeEqSet _ ((n, DomainSet{}), cs)
  -- Get references to the set and the function whose range it is a superset of
  = let funcSubsets = mapMaybe funcSubsetEqOf $
                      findInUncondForAllZ (isJust . funcSubsetEqOf . zipper) cs
        -- Reduce the functions to those whose values are equated to the values in the set
        fsToUse = flip filter funcSubsets $ \(_, f) ->
                  not $ null $ findInUncondForAll (funcValEqSetVal (hole f)) cs
        -- Transform the functions into new constraints, preserving structure
        csToAdd = flip mapMaybe fsToUse $ \(s, f) ->
                  let f' = hole f
                      in replaceHole [essence| range(&f') = &s |] <$>
                         (up f >>= up)
        in return ([], (csToAdd, []))
  where
    -- Get the function whose range is a subsetEq of the set
    funcSubsetEqOf z = case hole z of
                            [essence| range(&_) subsetEq &s |] | nameExpEq n s
                              -> (,) s <$> (down z >>= down)
                            [essence| &s supsetEq range(&_) |] | nameExpEq n s
                              -> (,) s <$> (down z >>= right >>= down)
                            _ -> Nothing
    -- Are the values of the function equal to the values of the set?
    funcValEqSetVal f [essence| forAll &x in &s . image(&f', &_) = &x' |]
      = nameExpEq n s && f == f' && refersTo x x'
    funcValEqSetVal f [essence| forAll &x in &s . &x' = image(&f', &_) |]
      = nameExpEq n s && f == f' && refersTo x x'
    funcValEqSetVal _ _ = False
funcRangeEqSet _ _ = return mempty

-- | Lens function over a binary expression.
type BinExprLens m = Proxy m -> (Expression -> Expression -> Expression,
                                 Expression -> m (Expression, Expression))

-- | Get the lens for an expression and the values it matches.
matching :: Expression
         -> [(BinExprLens Maybe, a)]
         -> Maybe (a, (Expression, Expression))
matching e ops = case mapMaybe (\(f1, f2) -> (,) f2 <$> match f1 e) ops of
                      [x] -> pure x
                      _   -> fail $ "no matching operator for expression: " <+> pretty e

-- -- | (In)equality operator lens pairs.
-- ineqOps :: [(BinExprLens Maybe, BinExprLens Identity)]
-- ineqOps = [ (opEq,  opEq)
--           , (opLt,  opLt)
--           , (opLeq, opLeq)
--           , (opGt,  opGt)
--           , (opGeq, opGeq)
--           ]

-- | Opposites of (in)equality operator lens pairs.
oppIneqOps :: [(BinExprLens Maybe, BinExprLens Identity)]
oppIneqOps = [ (opEq, opEq)
             , (opLt, opGt)
             , (opLeq, opGeq)
             , (opGt, opLt)
             , (opGeq, opLeq)
             ]

-- | (In)equality operator to size attribute modifier pairs.
ineqOccurAttrs :: [(BinExprLens Maybe, [(AttrName, Expression -> Maybe Expression)])]
ineqOccurAttrs = [ (opEq,  [ ("minOccur", Just), ("maxOccur", Just) ])
                 , (opLt,  [ ("maxOccur", Just . \x -> x - 1) ])
                 , (opLeq, [ ("maxOccur", Just) ])
                 , (opGt,  [ ("minOccur", Just . (+ 1)) ])
                 , (opGeq, [ ("minOccur", Just) ])
                 ]

-- -- | (In)equality operator to size attribute modifier pairs.
-- ineqSizeAttrs :: [(BinExprLens Maybe, (AttrName, Expression -> Expression))]
-- ineqSizeAttrs = [ (opEq,  (AttrName_size, id))
--                 , (opLt,  (AttrName_maxSize, \x -> x - 1))
--                 , (opLeq, (AttrName_maxSize, id))
--                 , (opGt,  (AttrName_minSize, (+1)))
--                 , (opGeq, (AttrName_minSize, id))
--                 ]

  -- where core :: (MonadFail m, MonadIO m, MonadLog m, MonadUserError m, NameGen m) => Model -> m Model
  --       core model = do model' <- foldM folder model [ functionAttributes
  --                                                    , setAttributes
  --                                                    , setConstraints
  --                                                    , variableSize
  --                                                    , mSetSizeOccur
  --                                                    , mSetOccur
  --                                                    , forAllIneqToIneqSum
  --                                                    , fasterIteration
  --                                                    ] >>= resolveNames
  --                       -- Make another pass if there were changes, but ignore models
  --                       -- with machine names, as they don't play well with resolveNames
  --                       if model == model' || any containsMachineName (suchThat model)
  --                          then return model'
  --                          else core model'
  --       -- Apply the function to every statement and fold it into the model
  --       folder :: (MonadFail m, MonadLog m)
  --              => Model -> (Model -> Declaration -> m Model) -> m Model
  --       folder m@Model { mStatements = stmts } f = foldM (applyToDecl f) m stmts
  --       -- Apply the function only to declarations
  --       applyToDecl f m (Declaration d) = f m d
  --       applyToDecl _ m _               = return m
  --       -- Push all of the constraints to a single statement at the back
  --       suchThatToBack m@Model { mStatements = stmts }
  --         = m { mStatements = suchThatToBack' stmts [] }
  --       suchThatToBack' [] es = [SuchThat es]
  --       suchThatToBack' (SuchThat cs:ss) es = suchThatToBack' ss (es `union` cs)
  --       suchThatToBack' (s:ss) es = s : suchThatToBack' ss es
  --       -- | Does an expression contain a reference with a machine name?
  --       containsMachineName = any isMachineName . universe
  --       isMachineName (Reference MachineName{} _) = True
  --       isMachineName _                           = False

-- -- | Make a maximum expression between two expressions.
-- --   Two max expressions are merged into one.
-- --   The max between a value and a max adds the value to the max (if not present).
-- --   If the expressions are the same, no max is made and the value is returned.
-- mkMax :: Expression -> Expression -> Expression
-- mkMax (Op (MkOpMax (OpMax (AbstractLiteral (AbsLitMatrix _ es1)))))
  --     (Op (MkOpMax (OpMax (AbstractLiteral (AbsLitMatrix _ es2)))))
  --       = make opMax $ fromList $ es1 `union` es2
-- mkMax i m@(Op (MkOpMax (OpMax (AbstractLiteral (AbsLitMatrix _ es)))))
  --         | i `elem` es = m
  --         | otherwise   = make opMax $ fromList $ i : es
-- mkMax m@(Op (MkOpMax (OpMax (AbstractLiteral (AbsLitMatrix _ es))))) i
  --         | i `elem` es = m
  --         | otherwise   = make opMax $ fromList $ i : es
-- mkMax i e | i == e      = e
  --         | otherwise   = make opMax $ fromList [ i, e ]

-- -- | Make a minimum expression between two expressions.
-- --   Two min expressions are merged into one.
-- --   The min between a value and a min adds the value to the min (if not present).
-- --   If the expressions are the same, no min is made and the value is returned.
-- mkMin :: Expression -> Expression -> Expression
-- mkMin (Op (MkOpMin (OpMin (AbstractLiteral (AbsLitMatrix _ es1)))))
  --     (Op (MkOpMin (OpMin (AbstractLiteral (AbsLitMatrix _ es2)))))
  --       = make opMin $ fromList $ es1 `union` es2
-- mkMin i m@(Op (MkOpMin (OpMin (AbstractLiteral (AbsLitMatrix _ es)))))
  --         | i `elem` es = m
  --         | otherwise   = make opMin $ fromList $ i : es
-- mkMin m@(Op (MkOpMin (OpMin (AbstractLiteral (AbsLitMatrix _ es))))) i
  --         | i `elem` es = m
  --         | otherwise   = make opMin $ fromList $ i : es
-- mkMin i e | i == e      = e
  --         | otherwise   = make opMin $ fromList [ i, e ]

-- -- | Lift a variable size constraint to an attribute.
-- variableSize :: (MonadFail m, MonadLog m)
  --            => Model        -- ^ Model as context.
  --            -> Declaration  -- ^ Declaration to give attribute.
  --            -> m Model      -- ^ Possibly updated model.
-- variableSize m (FindOrGiven Find n dom) | acceptedDom dom = do
  -- let attrs = mapMaybe (\e -> do
  --               -- The size of l is constrained by r
  --               ((attr, modifier), (l, r)) <- sizeConstraint e
  --               -- Act differently for different types of r
  --               if not (isFind r)
  --                  then case r of
  --                            [essence| image(&f, &_) |]
  --                              -> pure (l, attr, Just $ modifier [essence| max(range(&f)) |])
  --                            _ -> pure (l, attr, Just $ modifier r)
  --                  else fail $ "expression " <+> pretty r <+> " not a valid size attribute")
  --               $ findInUncondForAll (isJust . sizeConstraint) m
  -- -- addAttributesToDomain d [ ("total", Nothing), ("bijective", Nothing) ]
  -- foldM (\m' (l, attr, val) ->
  --        case domainOf l of
  --             Right DomainSet{}  -> pure $ declWithSizeAttr (attr, val) l m'
  --             Right DomainMSet{} -> pure $ declWithSizeAttr (attr, val) l m'
  --             Right (DomainAny _ (TypeSet _))  -> pure $ declWithSizeAttr (attr, val) l m'
  --             Right (DomainAny _ (TypeMSet _)) -> pure $ declWithSizeAttr (attr, val) l m'
  --             Right d   -> fail $ "unexpected size of domain: " <+> stringToDoc (show d)
  --             Left  msg -> fail msg)
  --       m attrs
  -- where
  --   acceptedDom DomainSet{}       = True
  --   acceptedDom DomainMSet{}      = True
  --   acceptedDom DomainFunction{}  = True
  --   acceptedDom _                 = False
  --   -- Is the interesting part of an expression a find variable?
  --   isFind Constant{}                                   = False
  --   isFind (Reference _ (Just (DeclNoRepr Find _ _ _))) = True
  --   isFind (Reference _ (Just (DeclHasRepr Find _ _)))  = True
  --   isFind [essence| image(&f, &_) |]                   = isFind f
  --   isFind [essence| &f(&_) |]                          = isFind f
  --   isFind e                                            = any isFind (children e)
  --   -- Update the declaration with a new size attribute
  --   declWithSizeAttr attr e m' = case FindOrGiven Find n <$> addSizeAttr attr e of
  --                                     Just decl -> updateDeclaration decl m'
  --                                     Nothing   -> m'
  --   -- Add a size attribute to a possibly nested domain
  --   addSizeAttr attr (Op (MkOpImage (OpImage (Reference n' _) _))) | n' == n
  --     = case dom of
  --            DomainFunction r as from d
  --              -> DomainFunction r as from <$> addAttributesToDomain d [ attr ]
  --            _ -> fail $ "find variable " <+> pretty n <+> " is not a function"
  --   addSizeAttr attr (Reference n' _) | n' == n
  --     = case dom of
  --            d@DomainSet{}  -> addAttributesToDomain d [ attr ]
  --            d@DomainMSet{} -> addAttributesToDomain d [ attr ]
  --            _ -> fail $ "find variable " <+> pretty n <+> " is not a set or multiset"
  --   addSizeAttr _ e = fail $ "unexpected expression: " <+> pretty e
-- variableSize m _ = return m

-- -- | Find an expression constraining the size of a variable and return the size attribute related
-- --   to it and the terms in the expression.
-- sizeConstraint :: (MonadFail m)
  --              => Expression  -- ^ Expression in which to look for the size constraint.
  --              -> m ((AttrName, Expression -> Expression),  -- ^ The size attribute modifier to apply
  --                    (Expression, Expression))              -- ^ and the terms of the constraint.
-- sizeConstraint e = do
  -- let failMsg = "expression " <+> pretty e <+> " not a constraint on variable size"
  -- case matching e oppIneqOps of
  --      Just (_, ([essence| |&_| |], _))
  --        -> case matching e ineqSizeAttrs of
  --                Just (attrMod, ([essence| |&l| |], r)) -> pure (attrMod, (l, r))
  --                _                                      -> fail failMsg
  --       -- If the terms are switched, try again with the reversed expression
  --      Just (oper, (l, r@[essence| |&_| |]))
  --        -> sizeConstraint (make oper r l)
  --      _ -> fail failMsg

-- -- | Merge an expression into the min field of a 'SizeAttr'.
-- mergeMinSize :: Expression -> SizeAttr Expression -> SizeAttr Expression
-- mergeMinSize e SizeAttr_None = SizeAttr_MinSize e
-- mergeMinSize e (SizeAttr_MinSize mn) = SizeAttr_MinSize $ mkMax e mn
-- mergeMinSize e (SizeAttr_MaxSize mx)
  -- | e == mx   = SizeAttr_Size e
  -- | otherwise = SizeAttr_MinMaxSize e mx
-- mergeMinSize e (SizeAttr_MinMaxSize mn mx) = SizeAttr_MinMaxSize (mkMax e mn) mx
-- mergeMinSize _ s = s

-- -- | Merge an expression into the min field of an 'OccurAttr'.
-- mergeMinOccur :: Expression -> OccurAttr Expression -> OccurAttr Expression
-- mergeMinOccur e OccurAttr_None = OccurAttr_MinOccur e
-- mergeMinOccur e (OccurAttr_MinOccur mn) = OccurAttr_MinOccur $ mkMax mn e
-- mergeMinOccur e (OccurAttr_MaxOccur mx) = OccurAttr_MinMaxOccur e mx
-- mergeMinOccur e (OccurAttr_MinMaxOccur mn mx) = OccurAttr_MinMaxOccur (mkMax e mn) mx

-- -- | Merge an expression into the max field of an 'OccurAttr'.
-- mergeMaxOccur :: Expression -> OccurAttr Expression -> OccurAttr Expression
-- mergeMaxOccur e OccurAttr_None = OccurAttr_MaxOccur e
-- mergeMaxOccur e (OccurAttr_MinOccur mn) = OccurAttr_MinMaxOccur mn e
-- mergeMaxOccur e (OccurAttr_MaxOccur mx) = OccurAttr_MaxOccur $ mkMin e mx
-- mergeMaxOccur e (OccurAttr_MinMaxOccur mn mx) = OccurAttr_MinMaxOccur mn (mkMin e mx)

-- -- | An (in)equality in a forAll implies that the (in)equality also applies to
-- --   the sums of both terms.
-- forAllIneqToIneqSum :: (MonadFail m, MonadLog m, NameGen m)
  --                   => Model
  --                   -> Declaration
  --                   -> m Model
-- forAllIneqToIneqSum m _
  -- = fmap (mergeConstraints m . map fromZipper . mapMaybe mkConstraint) $
  --         filterM partsAreNumeric $
  --         mapMaybe matchParts $
  --         findInUncondForAllZ (isJust . matchParts . zipper) m
  -- where
  --   matchParts :: ExpressionZ -> Maybe (Generator, Maybe ExpressionZ)
  --   matchParts z
  --     = case hole z of
  --            Op (MkOpAnd (OpAnd (Comprehension e [Generator g])))
  --              -> case matching e ineqOps of
  --                      Just (_, (e1, e2)) -> matchComponents z g e1 e2
  --                      _                  -> Nothing
  --            _ -> Nothing
  --   -- Match the components of the expression of interest
  --   matchComponents :: ExpressionZ -> Generator -> Expression -> Expression
  --                   -> Maybe (Generator, Maybe ExpressionZ)
  --   matchComponents z g e1 e2
  --     | refInExpr (namesFromGenerator g) e1 && refInExpr (namesFromGenerator g) e2
  --       = Just (g, down z >>= down)
  --   matchComponents _ _ _ _ = Nothing
  --   -- Is a name referred to in an expression?
  --   refInExpr names = any (hasName names) . universe
  --   hasName names (Reference name _) = name `elem` names
  --   hasName _     _                  = False
  --   -- Are the parts of the matched expression numeric?
  --   partsAreNumeric :: (MonadFail m, MonadLog m, NameGen m)
  --                   => (Generator, Maybe ExpressionZ) -> m Bool
  --   partsAreNumeric (_, Just z)
  --     = case matching (hole z) ineqOps of
  --            Just (_, (e1, e2)) -> (&&) <$> domainIsNumeric e1 <*> domainIsNumeric e2
  --            Nothing            -> return False
  --   partsAreNumeric _ = return False
  --   domainIsNumeric :: (MonadFail m, MonadLog m, NameGen m)
  --                   => Expression -> m Bool
  --   domainIsNumeric e = case domainOf e of
  --                            Right DomainInt{}           -> return True
  --                            Right (DomainAny _ TypeInt) -> return True
  --                            _                           -> return False
  --   -- Replace the forAll with the (in)equality between sums
  --   mkConstraint :: (Generator, Maybe ExpressionZ) -> Maybe ExpressionZ
  --   mkConstraint (gen, Just z)
  --     = case matching (hole z) ineqOps of
  --            Just (f, (e1, e2))
  --              -> let mkSumOf = Op . MkOpSum . OpSum . flip Comprehension [Generator gen]
  --                     e1' = mkSumOf e1
  --                     e2' = mkSumOf e2
  --                     -- Two steps to get out of the forAll, and replace it with the constraint
  --                     in replaceHole (make f e1' e2') <$> (up z >>= up)
  --            _ -> Nothing
  --   mkConstraint _ = Nothing

-- -- | Get the list of names from a generator.
-- namesFromGenerator :: Generator -> [Name]
-- namesFromGenerator (GenDomainNoRepr a _)  = namesFromAbstractPattern a
-- namesFromGenerator (GenDomainHasRepr n _) = [n]
-- namesFromGenerator (GenInExpr a _)        = namesFromAbstractPattern a

-- -- | Iterate slightly faster over a domain if generating two distinct variables.
-- fasterIteration :: (MonadFail m, MonadIO m, MonadLog m)
  --               => Model       -- ^ Model as context.
  --               -> Declaration -- ^ Ignored declaration.
  --               -> m Model     -- ^ Possibly updated model.
-- fasterIteration m _
  -- = foldM (\m' z -> do
  --         -- Find the equivalent variables
  --         equivs <- head <$> sequence [ findEquivVars (hole z) ]
  --         case doubleDistinctIter z of
  --              Nothing -> return m'
  --              -- Only apply to equivalent variables and make the new constraint
  --              Just v  -> case onlyEquivalent (equivs, v) >>= changeIterator of
  --                              Nothing -> return m'
  --                              -- Remove the old constraint
  --                              Just z' -> return $ flip removeConstraints [hole z] $
  --                                                  -- Add the new constraint
  --                                                  mergeConstraints m' [fromZipper z'])
  --         m $ findInUncondForAllZ (isJust . doubleDistinctIter . zipper) m 
  -- where
  --   -- Match the elemenents of interest in the constraint
  --   doubleDistinctIter z
  --     = case hole z of
  --            [essence| forAll &x, &y in &v, &x' != &y' . &_ |] | refersTo x x' && refersTo y y'
  --              -> Just ((x, x'), (y, y'), v, down z >>= down)
  --            [essence| forAll &x, &y : &d, &x' != &y' . &_ |] | refersTo x x' && refersTo y y'
  --              -> Just ((x, x'), (y, y'), Domain d, down z >>= down)
  --            _ -> Nothing
  --   -- Find which variables are equivalent in an expression
  --   findEquivVars :: (MonadIO m) => Expression -> m (Map Text Text)
  --   findEquivVars e = case e of
  --                          [essence| forAll &_, &_ : &_, &_ . &e' |]  -> liftIO $ findSyms e'
  --                          [essence| forAll &_, &_ in &_, &_ . &e' |] -> liftIO $ findSyms e'
  --                          _ -> return M.empty
  --   -- Find the symmetries in an expression
  --   findSyms :: Expression -> IO (Map Text Text)
  --   findSyms e = do
  --     let m' = flip mergeConstraints [e] $ removeConstraints m $ suchThat m
  --     let filename = ".tmp-variable-strengthening.json"
  --     outputVarSymBreaking filename m'
  --     symmetries <- ferret $ stringToText filename
  --     removeFile filename
  --     case (JSON.decodeStrict $ T.encodeUtf8 symmetries) :: Maybe [Map Text Text] of
  --          Nothing -> return M.empty
  --          Just ss -> return $ foldr M.union M.empty ss
  --   -- Only perform the modification if the variables are equivalent in the expression
  --   onlyEquivalent (es, v@((x, _), (y, _), _, _))
  --     = case namesFromAbstractPattern x of
  --            [Name nx] -> case namesFromAbstractPattern y of
  --                              [Name ny] -> case es M.!? nx of
  --                                                Just ny' | ny == ny' -> Just v
  --                                                _ -> Nothing
  --                              _         -> Nothing
  --            _         -> Nothing
  --   -- Change the iterator to use the new, faster notation
  --   changeIterator ((x, x'), (y, y'), v, Just z)
  --     = let e = hole z
  --           in case v of
  --                   r@Reference{}
  --                     -> case domainOf r of
  --                             Left _ -> Nothing
  --                             Right DomainSet{}
  --                               -> replaceHole [essence| forAll {&x, &y} subsetEq &v . &e |] <$>
  --                                  (up z >>= up)
  --                             Right _
  --                               -> replaceHole [essence| forAll &x, &y in &v, &y' > &x' . &e |] <$>
  --                                  (up z >>= up)
  --                   Op MkOpDefined{}
  --                     -> replaceHole [essence| forAll &x, &y in &v, &y' > &x' . &e |] <$>
  --                        (up z >>= up)
  --                   Domain d
  --                     -> replaceHole [essence| forAll &x, &y : &d, &y' > &x' . &e |] <$>
  --                        (up z >>= up)
  --                   _ -> Nothing
  --   changeIterator _ = Nothing

-- -- | Call ferret's symmetry detection on a JSON file
-- ferret :: Text -> IO Text
-- ferret path = shelly $ silently $ run "symmetry_detect" [ "--json", path ]
