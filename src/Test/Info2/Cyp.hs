module Test.Info2.Cyp (
  proof
, proofFile
) where

import Control.Applicative ((<$>))
import Control.Monad
import Control.Monad.State
import Data.Foldable (for_)
import Data.List
import qualified Data.Map.Strict as M
import Data.Maybe
import Data.Traversable (traverse)
import qualified Text.Parsec as Parsec
import Text.PrettyPrint (Doc, comma, fsep, punctuate, quotes, text, vcat, (<>), (<+>), ($+$))

import Test.Info2.Cyp.Env
import Test.Info2.Cyp.Parser
import Test.Info2.Cyp.Term
import Test.Info2.Cyp.Types
import Test.Info2.Cyp.Util

import Test.Info2.Cyp.Trace

{- Default constants -------------------------------------------------}

defConsts :: [String]
defConsts = [symPropEq]

{- Main -------------------------------------------------------------}

proofFile :: FilePath -> FilePath -> IO (Err ())
proofFile masterFile studentFile = do
    mContent <- readFile masterFile
    sContent <- readFile studentFile
    return $ proof (masterFile, mContent) (studentFile, sContent)

proof :: (String, String) -> (String, String) -> Err ()
proof (mName, mContent) (sName, sContent) = do
    env <- processMasterFile mName mContent
    lemmaStmts <- processProofFile env sName sContent
    results <- checkProofs env lemmaStmts
    case filter (not . contained results) $ goals env of
        [] -> return ()
        xs -> err $ indent (text "The following goals are still open:") $
            vcat $ map unparseProp xs
  where
    contained props goal = any (\x -> isJust $ matchProp goal (namedVal x) []) props

processMasterFile :: FilePath -> String -> Err Env
processMasterFile path content = errCtxtStr "Parsing background theory" $ do
    mResult <- eitherToErr $ Parsec.parse cthyParser path content
    dts <- readDataType mResult
    syms <- readSym mResult
    (fundefs, consts) <- readFunc syms mResult
    axs <- readAxiom consts mResult
    gls <- readGoal consts mResult
    return $ Env { datatypes = dts, axioms = fundefs ++ axs,
        constants = nub $ defConsts ++ consts, fixes = M.empty, goals = gls }

processProofFile :: Env -> FilePath -> String -> Err [ParseLemma]
processProofFile env path content = errCtxtStr "Parsing proof" $
    eitherToErr $ Parsec.runParser cprfParser env path content

checkProofs :: Env -> [ParseLemma] -> Err [Named Prop]
checkProofs env []  = Right $ axioms env
checkProofs env (l@(ParseLemma name prop _) : ls) = do
    proved <- errCtxt (text "Lemma:" <+> unparseRawProp prop) $
        checkProof env l
    checkProofs (env { axioms = Named name proved : axioms env }) ls



checkProof :: Env -> ParseLemma -> Err Prop
checkProof env (ParseLemma _ rprop (ParseEquation reqns)) = errCtxtStr "Equational proof" $ do
    let ((prop, eqns), env') = flip runState env $ do
          prop <- state (declareProp rprop)
          eqns <- traverse (state . declareTerm) reqns
          return (prop, eqns)
    validEquationProof (axioms env') eqns prop
    return prop
checkProof env (ParseLemma _ rprop (ParseInduction dtRaw overRaw casesRaw)) = errCtxt ctxtMsg $ do
    (prop, _) <- flip runStateT env $ do
        prop <- state (declareProp rprop)
        dt <- lift (validateDatatype dtRaw)
        over <- validateOver overRaw
        lift $ validateCases prop dt over casesRaw
        return prop
    return (generalizeExceptProp [] prop) -- XXX fix!
  where
    ctxtMsg = text "Induction over variable"
        <+> quotes (unparseRawTerm overRaw) <+> text "of type" <+> quotes (text dtRaw)

    validateDatatype name = case find (\dt -> getDtName dt == name) (datatypes env) of
        Nothing -> err $ fsep $
            [ text "Invalid datatype" <+> quotes (text name) <> text "."
            , text "Expected one of:" ]
            ++ punctuate comma (map (quotes . text . getDtName) $ datatypes env)
        Just dt -> Right dt

    validateOver t = do
        t' <- state (declareTerm t)
        case t' of
            Free v -> return v
            _ -> lift $ err $ text "Term" <+> quotes (unparseTerm t')
                <+> text "is not a valid induction variable"

    validateCases :: Prop -> DataType -> IdxName -> [ParseCase] -> Err ()
    validateCases prop dt over cases = do
        caseNames <- traverse (validateCase prop dt over) cases
        case missingCase caseNames of
            Nothing -> return ()
            Just (name, _) -> errStr $ "Missing case '" ++ name ++ "'"
      where
        missingCase caseNames = find (\(name, _) -> name `notElem` caseNames) (getDtConss dt)

    validateCase :: Prop -> DataType -> IdxName -> ParseCase -> Err String
    validateCase prop dt over pc = errCtxt (text "Case" <+> quotes (unparseRawTerm $ pcCons pc)) $ do
        (consName, _) <- flip runStateT env $ do
            caseT <- state (variantFixesTerm $ pcCons pc)
            (consName, consArgNs) <- lift $ lookupCons caseT dt
            let recArgNames = map snd . filter (\x -> fst x == TRec) $ consArgNs

            let subgoal = substFreeProp prop [(over, caseT)]
            toShow <- state (declareProp $ pcToShow pc)
            when (subgoal /= toShow) $ lift . err
                 $ text "'To show' does not match subgoal:"
                 `indent` (
                    text "To show:" <+> unparseProp toShow
                    $+$ debug (text "Subgoal:" <+> unparseProp subgoal))

            userHyps <- checkPcHyps prop over recArgNames $ pcIndHyps pc

            let ParseEquation eqns = pcEqns pc -- XXX
            eqns' <- traverse (state . declareTerm) eqns

            eqnProp <- lift $ validEquationProof (userHyps ++ axioms env) eqns' subgoal
            when (eqnProp /= toShow) $ lift $
                err $ (text "Result of equational proof" `indent` (unparseProp eqnProp))
                    $+$ (text "does not match stated goal:" `indent` (unparseProp toShow))
            return consName
        return consName


--        let (caseT, env') = variantFixesTerm env $ pcCons pc
--        (consName, consArgNs) <- lookupCons caseT dt
--        let argsNames = map snd consArgNs
--
--        let (prop', env'') = declareProp env' prop
--        let subgoal = substProp prop [(over, caseT)]
--        let toShow = generalizeExceptProp argsNames $ pcToShow pc
--        when (subgoal /= toShow) $ err
--             $ text "'To show' does not match subgoal:"
--             `indent` (text "To show: " <+> unparseProp toShow)
--
--        let indHyps = map (substProp prop . instOver) . filter (\x -> fst x == TRec) $ consArgNs
--
--        userHyps <- checkPcHyps argsNames indHyps $ pcIndHyps pc
--
--        let ParseEquation eqns = pcEqns pc -- XXX
--        let eqns' = generalizeExcept argsNames <$> eqns
--
--        eqnProp <- validEquationProof (userHyps ++ axioms env) eqns' subgoal
--        when (eqnProp /= toShow) $
--            err $ (text "Result of equational proof" `indent` (unparseProp eqnProp))
--                $+$ (text "does not match stated goal:" `indent` (unparseProp toShow))
--        return consName

    lookupCons t (DataType _ conss) = errCtxt invCaseMsg $ do
        (consName, consArgs) <- findCons cons
        argNames <- traverse argName args
        when (not $ nub args == args) $
            errStr "Constructor arguments must be distinct"
        when (not $ length args == length consArgs) $
            errStr "Invalid number of arguments"
        return (consName, zip consArgs argNames)
      where
        (cons, args) = stripComb t

        argName (Free v) = return v
        argName _ = errStr "Constructor arguments must be variables"

        findCons (Const name) = case find (\c -> fst c == name) conss of
            Nothing -> err (text "Invalid constructor, expected one of"
                <+> (fsep . punctuate comma . map (quotes . text . fst) $ conss))
            Just x -> return x
        findCons _ = errStr "Outermost symbol is not a constant"

        invCaseMsg = text "Invalid case" <+> quotes (unparseTerm t) <> comma

    -- XXX rename
    checkPcHyps :: Prop -> IdxName -> [IdxName] -> [Named RawProp] -> StateT Env (Either Doc) [Named Prop]
    checkPcHyps prop over recVars rpcHyps = do
        pcHyps <- traverse (traverse (state . declareProp)) rpcHyps
        let indHyps = map (substFreeProp prop . instOver) recVars
        lift $ for_ pcHyps $ \(Named name prop) -> case prop `elem` indHyps of
            True -> return ()
            False -> err $
                text ("Induction hypothesis " ++ name ++ " is not valid")
                `indent` (debug (unparseProp prop))
        return $ map (fmap $ generalizeExceptProp recVars) pcHyps
      where
        instOver n = [(over, Free n)]

    getDtConss (DataType _ conss) = conss
    getDtName (DataType n _) = n

validEqnSeq :: [Named Prop] -> EqnSeq Term -> Err (Term, Term)
validEqnSeq _ (Single t) = return (t, t)
validEqnSeq rules (Step t1 rule es)
    | rewritesToWith rule rules t1 t2 = do
        (_, tLast) <- validEqnSeq rules es
        return (t1, tLast)
    | otherwise = errCtxtStr ("Invalid proof step" ++ noRuleMsg) $ err $
        unparseTerm t1 $+$ text ("(by " ++ rule ++ ") " ++ symPropEq) <+> unparseTerm t2
        $+$ debug (text rule <> text ":" <+> vcat (map (unparseProp . namedVal) $ filter (\x -> namedName x == rule) rules))
  where
    (t2, _) = eqnSeqEnds es
    noRuleMsg
        | any (\x -> namedName x == rule) rules = ""
        | otherwise = " (no rules with name \"" ++ rule ++ "\")"

validEqnSeqq :: [Named Prop] -> EqnSeqq Term -> Err (Term, Term)
validEqnSeqq rules (EqnSeqq es1 Nothing) = validEqnSeq rules es1
validEqnSeqq rules (EqnSeqq es1 (Just es2)) = do
    (th1, tl1) <- validEqnSeq rules es1
    (th2, tl2) <- validEqnSeq rules es2
    case tl1 == tl2 of
        True -> return (th1, th2)
        False -> errCtxtStr "Two equation chains don't fit together:" $
            err $ unparseTerm tl1 $+$ text symPropEq $+$ unparseTerm tl2

validEquationProof :: [Named Prop] -> EqnSeqq Term -> Prop -> Err Prop
validEquationProof rules eqns goal = do
    (l,r) <- validEqnSeqq rules eqns
    let prop = Prop l r
    case isFixedProp prop $ goal of
        False -> err $ text "Proved proposition does not match goal:"
                     `indent` (unparseProp prop)
        True -> return prop

-- XXX Think about schemFrees again ...
isFixedProp :: Prop -> Prop -> Bool
isFixedProp fixedProp schemProp = isJust $ do
    inst <- map snd <$> matchProp fixedProp schemProp []
    --let (Prop schemL schemR) = schemProp
    --let schemFrees = collectFrees schemL $ collectFrees schemR $ []
    guard $ all (\x -> isFree x || isSchematic x) inst && nub inst == inst -- && null schemFrees

rewriteTop :: Term -> Prop -> Maybe Term
rewriteTop t (Prop lhs rhs) = fmap (subst rhs) $ match t lhs []

rewrite :: Term -> Prop -> [Term]
rewrite t@(Application f a) prop =
    maybeToList (rewriteTop t prop)
    ++ map (\x -> Application x a) (rewrite f prop)
    ++ map (Application f) (rewrite a prop)
rewrite t prop = maybeToList $ rewriteTop t prop

rewritesTo :: [Prop] -> Term -> Term -> Bool
rewritesTo rules l r = l == r || rewrites l r || rewrites r l
  where rewrites from to = any (\x -> isJust $ match to x []) $ concatMap (rewrite from) rules

rewritesToWith :: String -> [Named Prop] -> Term -> Term -> Bool
rewritesToWith name rules l r = rewritesTo (f rules) l r
  where f = map namedVal . filter (\x -> namedName x == name)
