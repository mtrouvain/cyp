module Test.Info2.Cyp.Env where

import qualified Data.Map.Strict as M

import Test.Info2.Cyp.Term
import Test.Info2.Cyp.Types

-- Environment to interpret declaration terms in ...
-- Not a real environment
declEnv :: Env
declEnv = Env { datatypes = [], axioms = [], constants = [], fixes = M.empty, goals = [] }

interpretTerm :: Env -> RawTerm -> Term
interpretTerm env rt = fmap f rt
  where
    f v = case M.lookup v (fixes env) of
        Nothing -> (v, 0)
        Just n -> (v, n)

interpretProp :: Env -> RawProp -> Prop
interpretProp env = propMap (interpretTerm env)

-- envAddFixes :: Env -> [String] -> Err Env
-- envAddFixes env xs
--     | any (`elem` frees env) xs = errStr "Variable already in use" -- XXX: show which variable!
--     | otherwise = return $ env { frees = xs ++ frees env }

foldMap :: (a -> b -> (c,b)) -> [a] -> b -> ([c], b)
foldMap _ [] s = ([], s)
foldMap f (x:xs) s = (x' : xs', s'')
  where
    (x', s') = f x s
    (xs', s'') = foldMap f xs s'

variantFixes :: [String] -> Env ->  ([IdxName], Env)
variantFixes xs env = (xs', env')
  where
    ins free = M.insertWith (\n _ -> n + 1) free 0
    fixes' = foldl (\e v -> ins v e) (fixes env) xs
    env' = env { fixes = fixes' }
    xs' = map (\x -> (x, M.findWithDefault 0 x fixes')) xs

variantFixesTerm :: RawTerm -> Env -> (Term, Env)
variantFixesTerm rt env = (interpretTerm env' rt, env')
  where
    (_, env') = variantFixes (collectFrees rt []) env

declareName :: String -> Env -> (IdxName, Env)
declareName v env = ((v, M.findWithDefault 0 v fixes'), env')
  where
    ins free = M.insertWith (\n _ -> n) free 0
    fixes' = ins v (fixes env)
    env' = env { fixes = fixes' }

declareTerm :: RawTerm -> Env -> (Term, Env)
declareTerm rt env = (interpretTerm env' rt, env')
  where
    ins free = M.insertWith (\n _ -> n) free 0
    fixes' = foldl (\e v -> ins v e) (fixes env) $ collectFrees rt []
    env' = env { fixes = fixes' }

declareProp :: RawProp -> Env -> (Prop, Env)
declareProp rprop@(Prop l r) env = (prop, env'')
  where
    (_, env') = declareTerm l env
    (_, env'') = declareTerm r env'
    prop = propMap (interpretTerm env'') rprop
