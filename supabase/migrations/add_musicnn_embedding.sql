-- Migration: add MusiCNN 200-dim timbral embedding column to track_embeddings
-- Run after add_dclap_embeddings.sql — requires the track_embeddings table to exist.
-- MusiCNN (MTT_musicnn, Last.fm-supervised) outperforms DCLAP for recommendation
-- ANN retrieval (Tamm & Aljanaki, RecSys '24 benchmark across 6 models).

-- ── Add column (idempotent) ──────────────────────────────────────────────────
alter table track_embeddings
    add column if not exists musicnn_embedding vector(200);

-- ── HNSW index — cosine ANN over 200-dim MusiCNN space ──────────────────────
-- Separate index from the 512-dim DCLAP index — pgvector requires one index
-- per column. m=16, ef_construction=64 matches DCLAP starting parameters.
create index if not exists track_embeddings_musicnn_hnsw_idx
    on track_embeddings
    using hnsw (musicnn_embedding vector_cosine_ops)
    with (m = 16, ef_construction = 64);

-- ── RPC: find_similar_tracks_musicnn ────────────────────────────────────────
-- Called by the Railway backend /musicnn-vector-search endpoint.
-- Only returns rows that have a musicnn_embedding (NULLs excluded by WHERE).
create or replace function find_similar_tracks_musicnn(
    query_embedding vector(200),
    match_count     int default 20
)
returns table (
    spotify_id   text,
    title        text,
    artist       text,
    similarity   double precision,
    arousal      double precision,
    valence_deam double precision,
    bpm          double precision
)
language sql stable
as $$
    select
        spotify_id,
        title,
        artist,
        1 - (musicnn_embedding <=> query_embedding)  as similarity,
        arousal,
        valence_deam,
        bpm
    from  track_embeddings
    where musicnn_embedding is not null
    order by musicnn_embedding <=> query_embedding
    limit match_count;
$$;
