-- | Supersede: replace the current memory of a ref with a new one.
--
-- 'Akyuu.Store' and 'Akyuu.Refs' do not know each other. A store holds
-- objects that never change. A ref says which object is the current one.
-- To "change" a memory, an agent adds a new object that has a
-- 'Akyuu.Graph.Supersedes' edge to the old one, and moves the ref to it.
-- This module does both steps, in the right order, and checks that no other
-- agent moved the ref in between.
--
-- The order of the steps is the reason why this is safe:
--
-- 1. Add the new object to the store.
-- 2. Move the ref, and only if it still has the value that the caller read
--    ('Akyuu.Refs.MustBe').
--
-- A crash after step 1 leaves an object that no ref points to. This is
-- harmless: GC collects it after its grace period. A crash cannot leave a
-- ref that points to an object that is not in the store.
--
-- If another agent moved the ref first, the call returns a 'Stale' error and
-- the ref does not change. The new object stays in the store. The caller can
-- read the ref again and decide what to do. It can also try again, with the
-- same memory, and the retry adds nothing new to the store if the object is
-- the same.
--
-- Functions return @IO (Either SupersedeError a)@. A caller never has to
-- catch an exception from this module.
module Akyuu.Supersede
  ( SupersedeError (..),
    supersede,
    supersedeFrom,
  )
where

import Akyuu.Graph (Edge (Edge), EdgeType (Supersedes))
import Akyuu.Id (Id)
import Akyuu.Memory (Memory (memEdges))
import Akyuu.Refs (Expected (MustBe), Name, Ref (current), RefError, Refs, getRef, setRef)
import Akyuu.Store (Store, StoreError)
import Akyuu.Store qualified as Store
import Control.Monad.Trans.Except (ExceptT (ExceptT), runExceptT, withExceptT)
import Data.Set qualified as Set

-- | Why 'supersede' or 'supersedeFrom' failed.
data SupersedeError
  = -- | A ref operation failed. This includes 'Akyuu.Refs.NoSuchRef' (there is
    -- nothing to supersede) and 'Akyuu.Refs.Stale' (another agent moved the
    -- ref first).
    SupersedeRef RefError
  | -- | The store could not add the new object.
    SupersedeStore StoreError
  deriving (Eq, Show)

-- | Replace the current memory of a ref with a new memory.
--
-- The function reads the ref, and then calls 'supersedeFrom' with the
-- current value that it read. Use it when the caller has no older read of the
-- ref. An agent that read a memory, thought about it, and now writes a new
-- version should call 'supersedeFrom' with the 'Id' that it read, so that
-- the check covers the time of its thinking.
--
-- Returns 'Akyuu.Refs.NoSuchRef' (in 'SupersedeRef') if the ref does not
-- exist. To make a new ref, add the memory with 'Akyuu.Store.add' and call
-- 'Akyuu.Refs.setRef' with 'Akyuu.Refs.MustBeAbsent'.
supersede :: Store -> Refs -> Name -> Memory -> IO (Either SupersedeError Id)
supersede st rs n m = runExceptT $ do
  old <- withExceptT SupersedeRef (ExceptT (getRef rs n))
  ExceptT (supersedeFrom st rs n (current old) m)

-- | Replace a ref with a new memory, if the ref still has the value @old@.
--
-- The steps:
--
-- 1. Add a 'Supersedes' edge from the new memory to @old@. If the memory has
--    that edge already, it does not change. The edges are a set.
-- 2. Add the memory to the store.
-- 3. Move the ref to the new 'Id' with @'MustBe' old@.
--
-- Returns the 'Id' of the new memory. The edges that the caller put in the
-- memory stay. The caller can add other 'Supersedes' edges, for example to
-- merge two memories into one.
--
-- If the ref is not @old@ any more, the result is
-- @'SupersedeRef' ('Akyuu.Refs.Stale' name current)@. The new object is then
-- in the store, and the ref did not change.
supersedeFrom :: Store -> Refs -> Name -> Id -> Memory -> IO (Either SupersedeError Id)
supersedeFrom st rs n old m = runExceptT $ do
  new <- withExceptT SupersedeStore (ExceptT (Store.add st replaced))
  _ <- withExceptT SupersedeRef (ExceptT (setRef rs n (MustBe old) new))
  pure new
  where
    replaced = m {memEdges = Set.insert (Edge Supersedes old) (memEdges m)}
