{-# LANGUAGE CPP #-}
#include "Runner.hs"

bf_pure :: Int             -- iteration counter
               -> Graph2       -- graph
               -> IS.IntSet    -- set of "seen" node labels, initially size 0
               -> IS.IntSet    -- set of "new" node labels, initially size 1
               -> WorkFn       -- function to be applied to each node
               -> IS.IntSet
bf_pure 0 _ seen_rank new_rank _ = do
  -- when verbose $ prnt $ "bf_pure finished! seen/new size: "
  --   ++ show (IS.size seen_rank, IS.size new_rank)
  (IS.union seen_rank new_rank)

bf_pure k !g  !seen_rank !new_rank !f = do 
  -- when verbose $ prnt  $"bf_traverse call... "
  --   ++ show k ++ " seen/new size "
  --   ++ show (IS.size seen_rank, IS.size new_rank)
  if IS.null new_rank
  then seen_rank
  else do
    -- Add new_rank stuff to the "seen" list
    let seen_rank' = IS.union seen_rank new_rank
        allNbr'    = IS.fold (\i acc -> IS.union (g V.! i) acc) 
                        IS.empty new_rank
        new_rank'  = IS.difference allNbr' seen_rank' 
    bf_pure (k-1) g seen_rank' new_rank' f


start_traverse :: Int       -- iteration counter
                  -> Graph2 -- graph
                  -> Int    -- start node
                  -> WorkFn -- function to be applied to each node
                  -> IO ()
start_traverse k !g startNode f = do
  do        
    putStrLn $ " * Running on " ++ show numCapabilities ++ " parallel resources..."
    let set = bf_pure k g IS.empty (IS.singleton startNode) f
--        set2 = Strat.parMap Strat.rdeepseq f (IS.toList set)
        set2 = Set.fromList (map f (IS.toList set))
        size = Set.size set2 
    evaluate set
    putStrLn $ " * Done with bf_pure..."    
    evaluate set2
    putStrLn$ " * Analyze function finished!"
    putStrLn$ "  * Set size: " ++ show size
    putStrLn$ "  * Set sum: " ++ show (Set.fold (\(_,x) y -> x+y) 0 set2)
