-- Bist relay v1. Apply with the project's SQL editor or a migration owner.
-- Client keys never receive access to the underlying tables or sequences.
BEGIN;

CREATE SCHEMA IF NOT EXISTS bist_sync_private;
REVOKE ALL ON SCHEMA bist_sync_private FROM PUBLIC, anon, authenticated;

CREATE TABLE IF NOT EXISTS bist_sync_private.instance (
    singleton boolean PRIMARY KEY DEFAULT true CHECK (singleton),
    server_id uuid NOT NULL DEFAULT gen_random_uuid()
);
INSERT INTO bist_sync_private.instance (singleton) VALUES (true)
ON CONFLICT (singleton) DO NOTHING;

CREATE TABLE IF NOT EXISTS bist_sync_private.events (
    seq bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
    event_id text NOT NULL CHECK (event_id ~ '^[0-9a-f]{64}$'),
    record jsonb NOT NULL,
    UNIQUE (user_id, event_id)
);
CREATE INDEX IF NOT EXISTS bist_sync_events_user_seq
    ON bist_sync_private.events (user_id, seq);

ALTER TABLE bist_sync_private.instance ENABLE ROW LEVEL SECURITY;
ALTER TABLE bist_sync_private.events ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON ALL TABLES IN SCHEMA bist_sync_private FROM PUBLIC, anon, authenticated;
REVOKE ALL ON ALL SEQUENCES IN SCHEMA bist_sync_private FROM PUBLIC, anon, authenticated;
-- RLS remains a second boundary if a future migration grants table access.
DROP POLICY IF EXISTS bist_events_owner_read ON bist_sync_private.events;
CREATE POLICY bist_events_owner_read ON bist_sync_private.events
    FOR SELECT TO authenticated USING (user_id = (SELECT auth.uid()));

CREATE OR REPLACE FUNCTION bist_sync_private.valid_stamp(p_stamp jsonb)
RETURNS boolean LANGUAGE plpgsql IMMUTABLE SET search_path = '' AS $$
DECLARE
    counter_text text;
BEGIN
    IF pg_catalog.jsonb_typeof(p_stamp) IS DISTINCT FROM 'object'
       OR NOT p_stamp ?& ARRAY['counter', 'deviceID']
       OR (SELECT count(*) FROM pg_catalog.jsonb_object_keys(p_stamp)) <> 2
       OR pg_catalog.jsonb_typeof(p_stamp->'counter') IS DISTINCT FROM 'number'
       OR pg_catalog.jsonb_typeof(p_stamp->'deviceID') IS DISTINCT FROM 'string'
       OR pg_catalog.octet_length(p_stamp->>'deviceID') NOT BETWEEN 1 AND 512 THEN
        RETURN false;
    END IF;
    counter_text := p_stamp->>'counter';
    IF counter_text !~ '^[1-9][0-9]{0,18}$' THEN RETURN false; END IF;
    RETURN counter_text::numeric < 9223372036854775807;
END;
$$;

CREATE OR REPLACE FUNCTION bist_sync_private.validate_value(p_value jsonb)
RETURNS void LANGUAGE plpgsql IMMUTABLE SET search_path = '' AS $$
DECLARE
    encoded text;
    decoded bytea;
BEGIN
    IF pg_catalog.jsonb_typeof(p_value) IS DISTINCT FROM 'string' THEN
        RAISE EXCEPTION USING ERRCODE='22023', MESSAGE='BIST_INVALID_RECORD';
    END IF;
    encoded := p_value #>> '{}';
    IF pg_catalog.octet_length(encoded) > 22369624 OR encoded ~ '[^A-Za-z0-9+/=]' THEN
        RAISE EXCEPTION USING ERRCODE='22023', MESSAGE='BIST_INVALID_RECORD';
    END IF;
    BEGIN
        decoded := pg_catalog.decode(encoded, 'base64');
        IF pg_catalog.octet_length(decoded) > 16777216
           OR pg_catalog.replace(pg_catalog.encode(decoded, 'base64'), E'\n', '') <> encoded THEN
            RAISE EXCEPTION 'invalid field bytes';
        END IF;
        -- json validates the encoded value without converting its contents to
        -- jsonb, which would reject valid escaped U+0000 note text.
        PERFORM pg_catalog.convert_from(decoded, 'UTF8')::json;
    EXCEPTION WHEN OTHERS THEN
        RAISE EXCEPTION USING ERRCODE='22023', MESSAGE='BIST_INVALID_RECORD';
    END;
END;
$$;

CREATE OR REPLACE FUNCTION bist_sync_private.validate_record(p_record jsonb)
RETURNS void LANGUAGE plpgsql IMMUTABLE SET search_path = '' AS $$
DECLARE
    allowed_fields text[];
    field_entry record;
    prior jsonb;
    context_entry record;
    current_counter numeric;
    context_counter text;
    deleted boolean := false;
BEGIN
    IF pg_catalog.jsonb_typeof(p_record) IS DISTINCT FROM 'object'
       OR NOT p_record ?& ARRAY['id','kind','fields']
       OR EXISTS (SELECT 1 FROM pg_catalog.jsonb_object_keys(p_record) k
                  WHERE k NOT IN ('id','kind','fields','deletion','restoration'))
       OR pg_catalog.jsonb_typeof(p_record->'id') IS DISTINCT FROM 'string'
       OR pg_catalog.jsonb_typeof(p_record->'kind') IS DISTINCT FROM 'string'
       OR pg_catalog.jsonb_typeof(p_record->'fields') IS DISTINCT FROM 'object' THEN
        RAISE EXCEPTION USING ERRCODE='22023', MESSAGE='BIST_INVALID_RECORD';
    END IF;
    IF p_record ? 'deletion' AND NOT bist_sync_private.valid_stamp(p_record->'deletion') THEN
        RAISE EXCEPTION USING ERRCODE='22023', MESSAGE='BIST_INVALID_RECORD';
    END IF;
    IF p_record ? 'restoration' AND NOT bist_sync_private.valid_stamp(p_record->'restoration') THEN
        RAISE EXCEPTION USING ERRCODE='22023', MESSAGE='BIST_INVALID_RECORD';
    END IF;
    IF p_record ? 'deletion' THEN
        deleted := NOT p_record ? 'restoration'
            OR (p_record->'restoration'->>'counter')::numeric < (p_record->'deletion'->>'counter')::numeric
            OR ((p_record->'restoration'->>'counter')::numeric = (p_record->'deletion'->>'counter')::numeric
                AND (p_record->'restoration'->>'deviceID') COLLATE "C" <= (p_record->'deletion'->>'deviceID') COLLATE "C");
    END IF;
    CASE p_record->>'kind'
    WHEN 'task' THEN
        IF p_record->>'id' !~ '^task\.[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' THEN
            RAISE EXCEPTION USING ERRCODE='22023', MESSAGE='BIST_INVALID_RECORD';
        END IF;
        allowed_fields := ARRAY['title','notes','nextAction','createdAt','lane','labelIDs','completion','placement','order'];
    WHEN 'label' THEN
        IF p_record->>'id' !~ '^label\.[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' THEN
            RAISE EXCEPTION USING ERRCODE='22023', MESSAGE='BIST_INVALID_RECORD';
        END IF;
        allowed_fields := ARRAY['name','color','order'];
    WHEN 'note' THEN
        IF p_record->>'id' <> 'note.main' OR deleted THEN
            RAISE EXCEPTION USING ERRCODE='22023', MESSAGE='BIST_INVALID_RECORD';
        END IF;
        allowed_fields := ARRAY['text'];
    ELSE
        RAISE EXCEPTION USING ERRCODE='22023', MESSAGE='BIST_INVALID_RECORD';
    END CASE;
    IF EXISTS (SELECT 1 FROM pg_catalog.jsonb_object_keys(p_record->'fields') k
               WHERE NOT k = ANY(allowed_fields))
       OR (NOT deleted AND NOT (p_record->'fields') ?& allowed_fields) THEN
        RAISE EXCEPTION USING ERRCODE='22023', MESSAGE='BIST_INVALID_RECORD';
    END IF;
    FOR field_entry IN SELECT * FROM pg_catalog.jsonb_each(p_record->'fields') LOOP
        IF pg_catalog.jsonb_typeof(field_entry.value) IS DISTINCT FROM 'object'
           OR NOT field_entry.value ?& ARRAY['value','stamp','history','context']
           OR (SELECT count(*) FROM pg_catalog.jsonb_object_keys(field_entry.value)) <> 4
           OR NOT bist_sync_private.valid_stamp(field_entry.value->'stamp')
           OR pg_catalog.jsonb_typeof(field_entry.value->'history') IS DISTINCT FROM 'array'
           OR pg_catalog.jsonb_typeof(field_entry.value->'context') IS DISTINCT FROM 'object' THEN
            RAISE EXCEPTION USING ERRCODE='22023', MESSAGE='BIST_INVALID_RECORD';
        END IF;
        PERFORM bist_sync_private.validate_value(field_entry.value->'value');
        current_counter := (field_entry.value->'stamp'->>'counter')::numeric;
        FOR context_entry IN SELECT * FROM pg_catalog.jsonb_each(field_entry.value->'context') LOOP
            context_counter := context_entry.value #>> '{}';
            IF pg_catalog.octet_length(context_entry.key) NOT BETWEEN 1 AND 512
               OR pg_catalog.jsonb_typeof(context_entry.value) IS DISTINCT FROM 'number'
               OR context_counter !~ '^[1-9][0-9]{0,18}$' THEN
                RAISE EXCEPTION USING ERRCODE='22023', MESSAGE='BIST_INVALID_RECORD';
            END IF;
            IF context_counter::numeric >= current_counter THEN
                RAISE EXCEPTION USING ERRCODE='22023', MESSAGE='BIST_INVALID_RECORD';
            END IF;
        END LOOP;
        FOR prior IN SELECT * FROM pg_catalog.jsonb_array_elements(field_entry.value->'history') LOOP
            IF pg_catalog.jsonb_typeof(prior) IS DISTINCT FROM 'object'
               OR NOT prior ?& ARRAY['value','stamp']
               OR (SELECT count(*) FROM pg_catalog.jsonb_object_keys(prior)) <> 2
               OR NOT bist_sync_private.valid_stamp(prior->'stamp') THEN
                RAISE EXCEPTION USING ERRCODE='22023', MESSAGE='BIST_INVALID_RECORD';
            END IF;
            PERFORM bist_sync_private.validate_value(prior->'value');
        END LOOP;
    END LOOP;
END;
$$;

-- Definer is necessary because authenticated roles intentionally cannot write
-- the immutable feed directly. Tenant ownership is derived only from auth.uid.
CREATE OR REPLACE FUNCTION public.bist_sync_push(p_events jsonb)
RETURNS jsonb LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path = '' AS $$
DECLARE
    caller uuid := auth.uid();
    item jsonb;
    prior_record jsonb;
    accepted jsonb := '[]'::jsonb;
    instance_id uuid;
BEGIN
    IF caller IS NULL THEN
        RAISE EXCEPTION USING ERRCODE='28000', MESSAGE='BIST_AUTH_REQUIRED';
    END IF;
    IF pg_catalog.jsonb_typeof(p_events) IS DISTINCT FROM 'array'
       OR pg_catalog.jsonb_array_length(p_events) NOT BETWEEN 1 AND 32
       OR pg_catalog.octet_length(p_events::text) > 67108864 THEN
        RAISE EXCEPTION USING ERRCODE='22023', MESSAGE='BIST_INVALID_BATCH';
    END IF;
    -- Acquire before allocating any identity. A late lower-sequence commit
    -- therefore cannot be hidden behind a cursor acknowledged by another RPC.
    PERFORM pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('bist-relay-v1:' || caller::text, 0));
    FOR item IN SELECT * FROM pg_catalog.jsonb_array_elements(p_events) LOOP
        IF pg_catalog.jsonb_typeof(item) IS DISTINCT FROM 'object'
           OR NOT item ?& ARRAY['event_id','record']
           OR (SELECT count(*) FROM pg_catalog.jsonb_object_keys(item)) <> 2
           OR pg_catalog.jsonb_typeof(item->'event_id') IS DISTINCT FROM 'string'
           OR item->>'event_id' !~ '^[0-9a-f]{64}$'
           OR pg_catalog.octet_length(item::text) > 50331648 THEN
            RAISE EXCEPTION USING ERRCODE='22023', MESSAGE='BIST_INVALID_EVENT';
        END IF;
        PERFORM bist_sync_private.validate_record(item->'record');
        SELECT record INTO prior_record FROM bist_sync_private.events
          WHERE user_id = caller AND event_id = item->>'event_id';
        IF FOUND THEN
            IF prior_record IS DISTINCT FROM item->'record' THEN
                RAISE EXCEPTION USING ERRCODE='22000', MESSAGE='BIST_EVENT_CONFLICT';
            END IF;
        ELSE
            INSERT INTO bist_sync_private.events (user_id,event_id,record)
              VALUES (caller,item->>'event_id',item->'record');
        END IF;
        accepted := accepted || pg_catalog.jsonb_build_array(item->>'event_id');
    END LOOP;
    SELECT server_id INTO STRICT instance_id FROM bist_sync_private.instance WHERE singleton;
    RETURN pg_catalog.jsonb_build_object('accepted',accepted,'server_id',instance_id);
END;
$$;

CREATE OR REPLACE FUNCTION public.bist_sync_pull(p_after bigint DEFAULT 0, p_limit integer DEFAULT 100)
RETURNS jsonb LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path = '' AS $$
DECLARE
    caller uuid := auth.uid();
    instance_id uuid;
    high_water bigint;
    row_value record;
    chosen bigint[] := ARRAY[]::bigint[];
    page_bytes bigint := 0;
    event_bytes bigint;
    next_cursor bigint := p_after;
    events jsonb;
    more boolean;
BEGIN
    IF caller IS NULL THEN
        RAISE EXCEPTION USING ERRCODE='28000', MESSAGE='BIST_AUTH_REQUIRED';
    END IF;
    IF p_after IS NULL OR p_after < 0 OR p_limit IS NULL OR p_limit NOT BETWEEN 1 AND 100 THEN
        RAISE EXCEPTION USING ERRCODE='22023', MESSAGE='BIST_INVALID_CURSOR';
    END IF;
    PERFORM pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('bist-relay-v1:' || caller::text, 0));
    SELECT coalesce(max(seq),0) INTO high_water FROM bist_sync_private.events WHERE user_id = caller;
    IF p_after > high_water THEN
        RAISE EXCEPTION USING ERRCODE='22023', MESSAGE='BIST_CURSOR_AHEAD';
    END IF;
    -- Iterate only until the byte budget is full. Avoid materializing 100
    -- maximum-size notes before applying the response limit.
    FOR row_value IN SELECT seq,event_id,record FROM bist_sync_private.events
        WHERE user_id = caller AND seq > p_after ORDER BY seq LIMIT p_limit LOOP
        event_bytes := pg_catalog.octet_length(pg_catalog.jsonb_build_object(
            'sequence',row_value.seq,'event_id',row_value.event_id,'record',row_value.record)::text) + 2;
        IF pg_catalog.cardinality(chosen) > 0 AND page_bytes + event_bytes > 33554432 THEN EXIT; END IF;
        chosen := pg_catalog.array_append(chosen,row_value.seq);
        page_bytes := page_bytes + event_bytes;
        next_cursor := row_value.seq;
        IF page_bytes >= 33554432 THEN EXIT; END IF;
    END LOOP;
    SELECT coalesce(pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
        'sequence',seq,'event_id',event_id,'record',record) ORDER BY seq),'[]'::jsonb)
      INTO events FROM bist_sync_private.events WHERE user_id = caller AND seq = ANY(chosen);
    SELECT EXISTS (SELECT 1 FROM bist_sync_private.events WHERE user_id = caller AND seq > next_cursor) INTO more;
    SELECT server_id INTO STRICT instance_id FROM bist_sync_private.instance WHERE singleton;
    RETURN pg_catalog.jsonb_build_object('events',events,'next_cursor',next_cursor,'has_more',more,'server_id',instance_id);
END;
$$;

REVOKE ALL ON ALL FUNCTIONS IN SCHEMA bist_sync_private FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.bist_sync_push(jsonb) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.bist_sync_pull(bigint,integer) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.bist_sync_push(jsonb) TO authenticated;
GRANT EXECUTE ON FUNCTION public.bist_sync_pull(bigint,integer) TO authenticated;

COMMENT ON FUNCTION public.bist_sync_push(jsonb) IS 'Bist v1 immutable revision upload for the authenticated owner. Bounded and idempotent.';
COMMENT ON FUNCTION public.bist_sync_pull(bigint,integer) IS 'Bist v1 owner-scoped, commit-ordered revision feed. BIST_CURSOR_AHEAD requires explicit recovery.';
NOTIFY pgrst, 'reload schema';
COMMIT;
