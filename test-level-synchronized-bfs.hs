{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE ScopedTypeVariables #-}

import LVarTraceInternal (newEmptySet, putInSet, Par, runParIO, ISet,
                          consumeSet)
import Control.Monad.Par.Combinator (parMapM)
import Control.Monad.Par.Class (ParFuture)
import Data.Maybe (fromJust)
import qualified Data.Set as Set
import Control.DeepSeq (NFData)
import Data.Traversable (Traversable)
import Debug.Trace (trace)

-- Graph representation
data Node a = Node
    { label    :: a
    , adjacent :: [Node a]
    }
  deriving Eq

data Graph a = Graph [Node a]
  deriving Show
           
-- Constructing a graph
-- (knot-tying trick from http://stackoverflow.com/a/9732857/415518)
mkGraph :: Eq a => [(a, [a])] -> Graph a
mkGraph links = Graph $ map snd nodeLookupList where
  mkNode (lbl, adj) = (lbl, Node lbl $ map lookupNode adj)
  nodeLookupList = map mkNode links
  lookupNode lbl = fromJust $ lookup lbl nodeLookupList
  
-- Neighbors of a node with a given label
nbrs :: Eq a => Graph a -> a -> [Node a]
nbrs (Graph []) _ = []
nbrs (Graph (n:ns)) lbl =
  if lbl == label n
  then adjacent n
  else nbrs (Graph ns) lbl
       
-- Neighbor labels of a node with a given label
nbrLabels :: (Eq a, Ord a) => Graph a -> a -> [a]
nbrLabels (Graph []) _ = []
nbrLabels (Graph (n:ns)) lbl =
  if lbl == label n
  then map label (adjacent n)
  else nbrLabels (Graph ns) lbl
  
-- Printing a graph
instance (Show a) => Show (Node a) where
  show (Node lbl adj) = show lbl ++ 
                        " --> " ++ show (map (show . label) adj) ++ "\n"
  
-- A graph
graphExample :: Graph Char
graphExample =
    mkGraph [('a', ['b', 'c']),
             ('b', ['a', 'd', 'e']),
             ('c', ['a', 'f', 'g']),
             ('d', ['b', 'h']),
             ('e', ['b', 'f', 'h']),
             ('f', ['c', 'e']),
             ('g', ['c']),
             ('h', ['d', 'e'])]

printGraph :: Show a => a -> IO ()
printGraph g =
  putStrLn . filter (`notElem` "'\"") . show $ g
  
{-

From Ryan's intro draft: "In a graph, find the connected component
containing a vertex V, and compute a function F over the labels of all
vertices in that component, returning a set of results."

Nothing about that problem statement says it has to be a breadth-first
search.  Should it?  (Also, this isn't really a "search", just a
breadth-first traversal.)

-}

main :: IO (Set.Set Char)
main =
  runParIO $ do
    let g = graphExample
    let v = 'a'
    let f = \x -> x
    l_acc <- newEmptySet
    result <- bf_traverse g l_acc Set.empty (Set.singleton v) f
    consumeSet l_acc
    -- return result


-- Takes a graph, an LVar, a set of "seen" node labels, a set of "new"
-- node labels, and the function f to be applied to each node.  We're
-- not actually doing anything with f yet.
bf_traverse :: forall a b . (Show a, Ord a, NFData a) =>
               (Graph a) -> ISet a -> Set.Set a -> Set.Set a -> (a -> b) ->
               Par (Set.Set b)
bf_traverse g l_acc seen_rank new_rank f =
  -- Nothing in the new_rank set means nothing left to traverse.
  if Set.null new_rank
  then return Set.empty
  else trace ("seen_rank: " ++ show seen_rank ++ "\n" ++
              "new_rank: " ++ show new_rank) $ do
    -- Add new_rank stuff to the "seen" list
    let seen_rank' =  Set.union seen_rank new_rank
    -- Add to the next rank, and to the output/accumulator:
    let add :: a -> Par (Set.Set a)
        add n = if Set.member n seen_rank'
                then return Set.empty
                else do putInSet n l_acc
                        return (Set.singleton n)
    
    new_rank' <- parMapM (parMapM add . (nbrLabels g)) (Set.toList new_rank)
    
    -- Flatten it out, this should be a parallel fold ideally:
    let new_rank'' = Set.unions $ concat new_rank'
    bf_traverse g l_acc seen_rank' new_rank'' f 



--------------------------------------------------------------------------------
-- Oops, turns out there is a painful reason that we don't have a traversable
-- instance for Set:
--
-- http://www.haskell.org/pipermail/haskell-cafe/2010-July/080978.html
--------------------------------------------------------------------------------
    
-- instance Functor Set.Set where
--   fmap f s = Set.map f s
--   -- fromList $ fmap f $ Set.toList s  

-- instance Traversable Set.Set where
  