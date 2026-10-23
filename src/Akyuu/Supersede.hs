-- | Supersede: replace the current memory of a ref with a new one.
--
-- 'Akyuu.Store' and 'Akyuu.Refs' do not know each other. A store holds
-- objects that never change. A ref says which object is the current one.
-- To "change" a memory, an agent adds a new object that has a
-- 'Akyuu.Graph.Supersedes' edge to the old one, and moves the ref to it.
-- This module does both steps, in the right order, and checks that no other
-- agent moved the ref in between.
--
-- The store mutation lock covers validation, object publication and the ref
-- update. A stale expectation is rejected before the object is written.
--
-- Publication is not a two-file transaction: a crash or I/O failure after
-- writing the object can leave a searchable, unreferenced object. The ref
-- is written last so it cannot name an object this operation has not saved.
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
import Akyuu.Mutation (Mutation, withMutation)
import Akyuu.Refs (Expected (MustBe), Name, Ref (current), RefError (Locked, RefIO), Refs, getRef, updateRef)
import Akyuu.Store (Store, StoreError, storeRoot)
import Akyuu.Store qualified as Store
import Control.Monad.Trans.Except (ExceptT (ExceptT), runExceptT, withExceptT)
import Data.Bifunctor (first)
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
-- The function reads and replaces the ref under the mutation lock. Use it
-- when the caller has no older read of the ref. An agent that read a memory,
-- thought about it, and now writes a new version should call 'supersedeFrom'
-- with the 'Id' that it read, so the check covers the time of its thinking.
--
-- Returns 'Akyuu.Refs.NoSuchRef' (in 'SupersedeRef') if the ref does not
-- exist. Use 'Akyuu.Refs.updateRef' with 'Akyuu.Refs.MustBeAbsent' and an
-- object producer to create a memory and reference under the same lock.
supersede :: Store -> Refs -> Name -> Memory -> IO (Either SupersedeError Id)
supersede st rs n m = withMutation (storeRoot st) (SupersedeRef Locked) (SupersedeRef . RefIO) $ \held -> runExceptT $ do
  old <- withExceptT SupersedeRef (ExceptT (getRef rs n))
  ExceptT (publish held st rs n (current old) m)

-- | Replace a ref with a new memory, if the ref still has the value @old@.
--
-- Under the store mutation lock, validate @old@ before publishing a memory
-- with a 'Supersedes' edge and moving the reference to it.
--
-- Returns the 'Id' of the new memory. The edges that the caller put in the
-- memory stay. The caller can add other 'Supersedes' edges, for example to
-- merge two memories into one.
--
-- A stale expectation leaves the store and reference unchanged.
supersedeFrom :: Store -> Refs -> Name -> Id -> Memory -> IO (Either SupersedeError Id)
supersedeFrom st rs n old m =
  withMutation (storeRoot st) (SupersedeRef Locked) (SupersedeRef . RefIO) $ \held ->
    publish held st rs n old m

publish :: Mutation -> Store -> Refs -> Name -> Id -> Memory -> IO (Either SupersedeError Id)
publish held st rs n old m =
  fmap current <$> updateRef held rs n (MustBe old) SupersedeRef (fmap (first SupersedeStore) (Store.addWith held st replaced))
  where
    replaced = m {memEdges = Set.insert (Edge Supersedes old) (memEdges m)}
