-- Migration: add DCLAP 512-dim neural embedding catalog
-- Run once in Supabase SQL Editor (or via supabase db push).

-- ── pgvector extension ───────────────────────────────────────────────────────
create extension if not exists vector;

-- ── track_embeddings table ──────────────────────────────────────────────────
-- Stores DCLAP embeddings + key audio fields for vector-search result hydration.
-- spotify_id is the primary key — re-embedding a known track simply updates it.
create table if not exists track_embeddings (
    spotify_id   text             primary key,
    title        text             not null,
    artist       text             not null,
    embedding    vector(512)      not null,
    arousal      double precision,          -- DEAM arousal [0,1]
    valence_deam double precision,          -- DEAM valence [0,1]
    bpm          double precision,
    created_at   timestamptz      default now(),
    updated_at   timestamptz      default now()
);

-- ── HNSW index — cosine ANN ─────────────────────────────────────────────────
-- m=16, ef_construction=64 is the pgvector recommended starting point for
-- 512-dim vectors with a catalog expected to stay under ~1M rows.
create index if not exists track_embeddings_hnsw_idx
    on track_embeddings
    using hnsw (embedding vector_cosine_ops)
    with (m = 16, ef_construction = 64);

-- ── updated_at trigger ──────────────────────────────────────────────────────
create or replace function set_updated_at()
returns trigger language plpgsql as $$
begin
    new.updated_at = now();
    return new;
end;
$$;

drop trigger if exists track_embeddings_updated_at on track_embeddings;
create trigger track_embeddings_updated_at
    before update on track_embeddings
    for each row execute procedure set_updated_at();

-- ── RPC: find_similar_tracks ────────────────────────────────────────────────
-- Called by the Railway backend /vector-search endpoint.
-- Returns top match_count rows ordered by cosine similarity (descending).
-- similarity = 1 − cosine_distance, so 1.0 = identical, 0.0 = orthogonal.
create or replace function find_similar_tracks(
    query_embedding vector(512),
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
        1 - (embedding <=> query_embedding)  as similarity,
        arousal,
        valence_deam,
        bpm
    from  track_embeddings
    order by embedding <=> query_embedding
    limit match_count;
$$;
