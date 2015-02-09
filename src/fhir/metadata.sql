-- #import ../coll.sql

CREATE TABLE this.profile (
  id text PRIMARY KEY,
  base text,
  name text,
  type text,
  content jsonb,
  installed boolean DEFAULT false
);

CREATE TABLE this.profile_elements (
  profile_id text,
  path text[],
  min text,
  max text,
  type text[],
  formal text,
  comments text,
  isSummary boolean,
  ref_type text[],
  PRIMARY KEY(profile_id, path)
);

func profile_to_resource_type(_ref_ text) RETURNS text
  select replace(_ref_, 'http://hl7.org/fhir/Profile/', '')

func! load_elements(_prof_ jsonb) returns text
 with inserted as (
    INSERT INTO this.profile_elements
    (profile_id, path, min, max, type, formal, comments, isSummary, ref_type)
    select
      _prof_->>'id',
      regexp_split_to_array(x->>'path', '\.'),
      x->>'min',
      x->>'max',
      (
        SELECT array_agg(y->>'code')
        FROM jsonb_array_elements(x->'type') y
        WHERE y->>'code' <> 'Reference'
      ),
      x->>'formal',
      x->>'comments',
      x->>'isSummary' = 'true',
      (
        SELECT array_agg(this.profile_to_resource_type(y->>'profile'))
         FROM jsonb_array_elements(x->'type') y
         WHERE y->>'code' = 'Reference'
      )
      from jsonb_array_elements(_prof_#>'{snapshot, element}') x
      WHERE x->>'path' <> 'value' AND jsonb_typeof(x) <> 'null'
    returning path::text
 ) select string_agg(path, ',') from inserted

func! load_profile(_prof_ jsonb) returns text
   INSERT INTO this.profile
   (id, name, type, base, content)
   SELECT id, name, type, base, content FROM (
     SELECT _prof_#>>'{id}' as id,
            _prof_#>>'{name}' as name,
            _prof_#>>'{type}' as type,
            _prof_#>>'{base}' as base,
            _prof_ as content,
            this.load_elements(_prof_)
   ) _
   RETURNING id

-- insert profiles from bundle into meta tables
func! load_bundle(bundle jsonb) returns text[]
 SELECT array_agg(this.load_profile(x->'resource'))
   FROM jsonb_array_elements(bundle#>'{entry}') x
   WHERE x#>>'{resource,resourceType}' = 'Profile'

CREATE TABLE this.search_type_to_type AS
        SELECT 'date' as stp,  '{date,dateTime,instant,Period,Timing}'::text[] as tp
  UNION SELECT 'token' as stp, '{boolean,code,CodeableConcept,Coding,Identifier,oid,Resource,string,uri}'::text[] as tp
  UNION SELECT 'string' as stp, '{Address,Attachment,CodeableConcept,ContactPoint,HumanName,Period,Quantity,Ratio,Resource,SampledData,string,uri}'::text[] as tp
  UNION SELECT 'number' as stp, '{integer,decimal,Duration,Quantity}'::text[] as tp
  UNION SELECT 'reference' as stp, '{Reference}'::text[] as tp
  UNION SELECT 'quantity' as stp, '{Quantity}'::text[] as tp;

-- insead using recursive type resoultion
-- we just hadcode missed
CREATE TABLE this.hardcoded_complex_params (
  path text[],
  type text
);

INSERT INTO this.hardcoded_complex_params
(path, type) VALUES
('{ConceptMap,concept,map,product,concept}','uri'),
('{DiagnosticOrder,item,event,dateTime}'   ,'dataTime'),
('{DiagnosticOrder,item,event,status}'     ,'code'),
('{Patient,name,family}'                   ,'string'),
('{Patient,name,given}'                    ,'string'),
('{Provenance,period,end}'                 ,'dateTime'),
('{Provenance,period,start}'               ,'dataTime');

CREATE TABLE this.searchparameter (
  id text PRIMARY KEY,
  name text,
  base text, --resource text,
  xpath text,
  path text[],
  search_type text,
  is_primitive boolean,
  type text,
  content jsonb
);

func! load_searchparameters(bundle jsonb) returns text[]
   with params as (
     SELECT x#>>'{resource,id}' as id,
            x#>>'{resource,name}' as name,
            x#>>'{resource,base}' as base,
            x#>>'{resource,xpath}' as xpath,
            regexp_split_to_array(replace(x#>>'{resource,xpath}','f:' ,'') , '/') as path,
            x#>>'{resource,type}' as search_type,
            x->'resource' as content
       FROM jsonb_array_elements(bundle#>'{entry}') x
      WHERE x#>>'{resource,resourceType}' = 'SearchParameter'
   ),
   -- add type information from profile_elements
   extended_params as (
    SELECT x.id, x.name, x.base, x.xpath, x.path, x.search_type, x.content,
      unnest(COALESCE(e.type, ARRAY[hp.type]::text[])) as type
      FROM params x
      LEFT JOIN this.profile_elements e
      ON e.path = x.path
      LEFT JOIN this.hardcoded_complex_params hp
      ON hp.path = x.path
      WHERE array_length(x.path,1) > 1
   ),
   inserted as (
     INSERT INTO this.searchparameter
     (id, name, base, xpath, search_type, type, content, path, is_primitive)
     SELECT id, name, base, xpath, search_type, type, content,
       CASE WHEN coll._last(path) ilike '%[x]' THEN
         coll._butlast(path) || (replace(coll._last(path),'[x]','') || type)::text
       ELSE
         path
       END as path,
       substr(type, 1,1)=lower(substr(type, 1,1)) as is_primitive
       from  extended_params
     RETURNING id
   )
   SELECT array_agg(x.id) FROM inserted x

\set datatypes `cat fhir/profiles-types.json`
select array_length(this.load_bundle(:'datatypes'), 1);

\set profs `cat fhir/profiles-resources.json`
SELECT array_length(metadata.load_bundle(:'profs'),1);

\set searchp `cat fhir/search-parameters.json`
select array_length(this.load_searchparameters(:'searchp'), 1);