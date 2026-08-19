-- ============================================================
-- PROMPTVERSE 2.0 — BANCO DE DADOS COMPLETO (Supabase / PostgreSQL)
-- Execute este arquivo inteiro no SQL Editor do Supabase.
-- Ordem: extensões -> tipos -> tabelas -> índices -> funções
--        -> triggers -> RLS -> webhooks Cakto -> seeds
-- ============================================================

-- ============================================================
-- 1. EXTENSÕES
-- ============================================================
create extension if not exists "pgcrypto";   -- gen_random_uuid(), hashing
create extension if not exists "citext";     -- e-mail sem diferenciar maiúscula

-- ============================================================
-- 2. TIPOS (ENUMS)
-- ============================================================
do $$ begin
  create type plan_type      as enum ('starter','pro','lifetime');
exception when duplicate_object then null; end $$;

do $$ begin
  create type license_status as enum ('active','expired','canceled','refunded','pending');
exception when duplicate_object then null; end $$;

do $$ begin
  create type user_status    as enum ('active','suspended','pending');
exception when duplicate_object then null; end $$;

do $$ begin
  create type sale_status    as enum ('approved','pending','canceled','refunded');
exception when duplicate_object then null; end $$;

-- ============================================================
-- 3. TABELAS
-- ============================================================

-- ---------- 3.1 USERS ----------
-- IMPORTANTE: a senha NÃO fica aqui.
-- O Supabase Auth guarda a senha com hash em auth.users (schema protegido).
-- Esta tabela é o perfil público, ligado 1:1 ao auth.users pelo id.
create table if not exists public.users (
  id            uuid primary key references auth.users(id) on delete cascade,
  name          text,
  email         citext unique not null,
  plan          plan_type,
  status        user_status not null default 'active',
  avatar_url    text,
  tiktok_handle text,
  phone         text,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);
comment on table  public.users is 'Perfil do usuário. Autenticação e senha ficam em auth.users.';
comment on column public.users.plan is 'Plano vigente, sincronizado pela licença ativa.';

-- ---------- 3.2 LICENSES ----------
-- expires_at NULL = plano vitalício (lifetime)
create table if not exists public.licenses (
  id           uuid primary key default gen_random_uuid(),
  user_id      uuid not null references public.users(id) on delete cascade,
  license_key  text unique not null,
  plan         plan_type not null,
  expires_at   timestamptz,
  status       license_status not null default 'active',
  order_id     text,                       -- id do pedido na Cakto
  gateway      text default 'cakto',
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now(),
  constraint lifetime_sem_validade
    check (plan <> 'lifetime' or expires_at is null)
);

-- ---------- 3.3 SALES ----------
create table if not exists public.sales (
  id           uuid primary key default gen_random_uuid(),
  user_id      uuid not null references public.users(id) on delete cascade,
  product_id   uuid,
  product_name text not null,
  commission   numeric(12,2) not null default 0 check (commission >= 0),
  gmv          numeric(12,2) not null default 0 check (gmv >= 0),
  status       sale_status not null default 'approved',
  sale_date    date not null default current_date,
  created_at   timestamptz not null default now()
);

-- ---------- 3.4 FOLLOWERS ----------
-- 1 registro por dia por usuário (snapshot para montar os gráficos)
create table if not exists public.followers (
  id              uuid primary key default gen_random_uuid(),
  user_id         uuid not null references public.users(id) on delete cascade,
  followers_count integer not null default 0 check (followers_count >= 0),
  snapshot_date   date not null default current_date,
  created_at      timestamptz not null default now(),
  unique (user_id, snapshot_date)
);

-- ---------- 3.5 NOTIFICATIONS ----------
create table if not exists public.notifications (
  id         uuid primary key default gen_random_uuid(),
  user_id    uuid not null references public.users(id) on delete cascade,
  title      text not null,
  message    text,
  type       text default 'info',   -- sale | commission | follower | goal | info
  read       boolean not null default false,
  created_at timestamptz not null default now()
);

-- ---------- 3.6 PRODUCTS (catálogo global) ----------
create table if not exists public.products (
  id            uuid primary key default gen_random_uuid(),
  title         text not null,
  description   text,
  video_url     text,                -- vídeo de referência
  affiliate_url text,                -- link de afiliação
  image_url     text,
  copy          text,                -- copy validada
  category      text,                -- nicho
  price         numeric(12,2),
  commission    numeric(12,2),
  benefits      jsonb default '[]'::jsonb,
  angles        jsonb default '[]'::jsonb,
  ctas          jsonb default '[]'::jsonb,
  pov           jsonb default '[]'::jsonb,
  format        text default 'POV',  -- POV | UGC
  target        text,                -- público-alvo
  active        boolean not null default true,
  position      integer default 0,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);

-- ---------- 3.7 PROMPTS (biblioteca + bônus) ----------
create table if not exists public.prompts (
  id         uuid primary key default gen_random_uuid(),
  title      text not null,
  category   text not null,
  content    text not null,
  description text,
  image_url  text,
  is_bonus   boolean not null default false,
  min_plan   plan_type not null default 'starter',
  position   integer default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- favoritos e histórico de uso de prompts
create table if not exists public.prompt_favorites (
  user_id    uuid not null references public.users(id) on delete cascade,
  prompt_id  uuid not null references public.prompts(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (user_id, prompt_id)
);

create table if not exists public.prompt_usage (
  id         uuid primary key default gen_random_uuid(),
  user_id    uuid not null references public.users(id) on delete cascade,
  prompt_id  uuid not null references public.prompts(id) on delete cascade,
  used_at    timestamptz not null default now()
);

-- favoritos de produtos
create table if not exists public.product_favorites (
  user_id    uuid not null references public.users(id) on delete cascade,
  product_id uuid not null references public.products(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (user_id, product_id)
);

-- ---------- 3.8 COMMUNITY_RANKING ----------
-- 1 linha por usuário por mês (month = primeiro dia do mês)
create table if not exists public.community_ranking (
  id         uuid primary key default gen_random_uuid(),
  user_id    uuid not null references public.users(id) on delete cascade,
  gmv        numeric(12,2) not null default 0,
  commission numeric(12,2) not null default 0,
  xp         integer not null default 0,
  month      date not null,
  updated_at timestamptz not null default now(),
  unique (user_id, month)
);

-- ---------- 3.9 AI_MODELS ----------
create table if not exists public.ai_models (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid not null references public.users(id) on delete cascade,
  model_name  text not null,
  gender      text,
  skin_tone   text,
  eye_color   text,
  eye_shape   text,
  hair_type   text,
  hair_color  text,
  face_type   text,
  nose_type   text,
  mouth_type  text,
  ears        text,
  height      text,
  age_range   text,
  expression  text,
  outfit      text,
  scenario    text,
  photo_style text,
  prompt      text,          -- prompt gerado
  image_url   text,          -- foto salva pelo usuário
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);

-- ---------- 3.10 AULAS E PROGRESSO (Método 2K) ----------
create table if not exists public.lessons (
  id       uuid primary key default gen_random_uuid(),
  number   integer not null unique,
  title    text not null,
  description text,
  duration text,
  video_url text
);

create table if not exists public.lesson_progress (
  user_id      uuid not null references public.users(id) on delete cascade,
  lesson_id    uuid not null references public.lessons(id) on delete cascade,
  completed    boolean not null default false,
  completed_at timestamptz,
  primary key (user_id, lesson_id)
);

-- ---------- 3.11 LIVES ----------
create table if not exists public.lives (
  id         uuid primary key default gen_random_uuid(),
  user_id    uuid not null references public.users(id) on delete cascade,
  title      text not null,
  scheduled_at timestamptz not null,
  notes      text,
  created_at timestamptz not null default now()
);

-- ---------- 3.12 CHAVE ESTRANGEIRA DE SALES -> PRODUCTS ----------
-- (criada aqui porque products é definida depois de sales)
do $$ begin
  alter table public.sales
    add constraint sales_product_fk
    foreign key (product_id) references public.products(id) on delete set null;
exception when duplicate_object then null; end $$;

-- ============================================================
-- 4. ÍNDICES
-- ============================================================
create index if not exists idx_users_email            on public.users (email);
create index if not exists idx_users_plan             on public.users (plan);

create index if not exists idx_licenses_user          on public.licenses (user_id);
create index if not exists idx_licenses_key           on public.licenses (license_key);
create index if not exists idx_licenses_status        on public.licenses (status);
create index if not exists idx_licenses_order         on public.licenses (order_id);

create index if not exists idx_sales_user_date        on public.sales (user_id, sale_date desc);
create index if not exists idx_sales_status           on public.sales (status);

create index if not exists idx_followers_user_date    on public.followers (user_id, snapshot_date desc);

create index if not exists idx_notif_user_unread      on public.notifications (user_id, read, created_at desc);

create index if not exists idx_products_category      on public.products (category) where active;
create index if not exists idx_products_position      on public.products (position);

create index if not exists idx_prompts_category       on public.prompts (category);
create index if not exists idx_prompts_bonus          on public.prompts (is_bonus, position);

create index if not exists idx_ranking_month_gmv      on public.community_ranking (month, gmv desc);
create index if not exists idx_ranking_user           on public.community_ranking (user_id);

create index if not exists idx_ai_models_user         on public.ai_models (user_id, created_at desc);
create index if not exists idx_prompt_usage_user      on public.prompt_usage (user_id, used_at desc);
create index if not exists idx_lives_user             on public.lives (user_id, scheduled_at);

-- ============================================================
-- 5. FUNÇÕES
-- ============================================================

-- 5.1 updated_at automático
create or replace function public.set_updated_at()
returns trigger language plpgsql as $$
begin
  new.updated_at = now();
  return new;
end $$;

-- 5.2 gerador de chave de acesso: PV2-XXXX-XXXX
create or replace function public.generate_license_key()
returns text language plpgsql as $$
declare
  chars text := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789'; -- sem I, O, 0, 1
  k text;
  i int;
begin
  loop
    k := 'PV2-';
    for i in 1..4 loop k := k || substr(chars, floor(random()*length(chars)+1)::int, 1); end loop;
    k := k || '-';
    for i in 1..4 loop k := k || substr(chars, floor(random()*length(chars)+1)::int, 1); end loop;
    exit when not exists (select 1 from public.licenses where license_key = k);
  end loop;
  return k;
end $$;

alter table public.licenses
  alter column license_key set default public.generate_license_key();

-- 5.3 cria o perfil quando nasce um usuário no Auth
create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into public.users (id, email, name)
  values (
    new.id,
    new.email,
    coalesce(new.raw_user_meta_data->>'name', split_part(new.email,'@',1))
  )
  on conflict (id) do nothing;
  return new;
end $$;

-- 5.4 licença ativa do usuário logado
create or replace function public.has_active_license()
returns boolean language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from public.licenses l
    where l.user_id = auth.uid()
      and l.status = 'active'
      and (l.expires_at is null or l.expires_at > now())
  );
$$;

-- 5.5 plano vigente do usuário logado
create or replace function public.current_plan()
returns plan_type language sql stable security definer set search_path = public as $$
  select l.plan
  from public.licenses l
  where l.user_id = auth.uid()
    and l.status = 'active'
    and (l.expires_at is null or l.expires_at > now())
  order by case l.plan when 'lifetime' then 3 when 'pro' then 2 else 1 end desc
  limit 1;
$$;

-- 5.6 o plano atual cobre o mínimo exigido?
create or replace function public.plan_covers(required plan_type)
returns boolean language sql stable security definer set search_path = public as $$
  select case coalesce(public.current_plan()::text,'none')
           when 'lifetime' then 3 when 'pro' then 2 when 'starter' then 1 else 0 end
       >= case required::text
           when 'lifetime' then 3 when 'pro' then 2 else 1 end;
$$;

-- 5.7 sincroniza users.plan quando a licença muda
create or replace function public.sync_user_plan()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  update public.users u
     set plan = (
       select l.plan from public.licenses l
       where l.user_id = u.id and l.status = 'active'
         and (l.expires_at is null or l.expires_at > now())
       order by case l.plan when 'lifetime' then 3 when 'pro' then 2 else 1 end desc
       limit 1
     ),
     updated_at = now()
   where u.id = coalesce(new.user_id, old.user_id);
  return coalesce(new, old);
end $$;

-- 5.8 atualiza o ranking do mês a cada venda aprovada
create or replace function public.refresh_ranking()
returns trigger language plpgsql security definer set search_path = public as $$
declare m date := date_trunc('month', coalesce(new.sale_date, current_date))::date;
begin
  insert into public.community_ranking (user_id, month, gmv, commission, xp)
  select coalesce(new.user_id, old.user_id), m,
         coalesce(sum(gmv),0), coalesce(sum(commission),0), coalesce(count(*),0) * 10
    from public.sales
   where user_id = coalesce(new.user_id, old.user_id)
     and status = 'approved'
     and date_trunc('month', sale_date)::date = m
  on conflict (user_id, month) do update
     set gmv = excluded.gmv,
         commission = excluded.commission,
         xp = excluded.xp,
         updated_at = now();
  return coalesce(new, old);
end $$;

-- ============================================================
-- 6. TRIGGERS
-- ============================================================
drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

drop trigger if exists trg_users_updated     on public.users;
create trigger trg_users_updated     before update on public.users     for each row execute function public.set_updated_at();
drop trigger if exists trg_licenses_updated  on public.licenses;
create trigger trg_licenses_updated  before update on public.licenses  for each row execute function public.set_updated_at();
drop trigger if exists trg_products_updated  on public.products;
create trigger trg_products_updated  before update on public.products  for each row execute function public.set_updated_at();
drop trigger if exists trg_prompts_updated   on public.prompts;
create trigger trg_prompts_updated   before update on public.prompts   for each row execute function public.set_updated_at();
drop trigger if exists trg_models_updated    on public.ai_models;
create trigger trg_models_updated    before update on public.ai_models for each row execute function public.set_updated_at();

drop trigger if exists trg_sync_plan on public.licenses;
create trigger trg_sync_plan
  after insert or update or delete on public.licenses
  for each row execute function public.sync_user_plan();

drop trigger if exists trg_refresh_ranking on public.sales;
create trigger trg_refresh_ranking
  after insert or update or delete on public.sales
  for each row execute function public.refresh_ranking();

-- ============================================================
-- 7. ROW LEVEL SECURITY
-- ============================================================
alter table public.users             enable row level security;
alter table public.licenses          enable row level security;
alter table public.sales             enable row level security;
alter table public.followers         enable row level security;
alter table public.notifications     enable row level security;
alter table public.products          enable row level security;
alter table public.prompts           enable row level security;
alter table public.prompt_favorites  enable row level security;
alter table public.prompt_usage      enable row level security;
alter table public.product_favorites enable row level security;
alter table public.community_ranking enable row level security;
alter table public.ai_models         enable row level security;
alter table public.lessons           enable row level security;
alter table public.lesson_progress   enable row level security;
alter table public.lives             enable row level security;

-- ---------- USERS ----------
drop policy if exists users_select_own on public.users;
create policy users_select_own on public.users
  for select using (auth.uid() = id);
drop policy if exists users_update_own on public.users;
create policy users_update_own on public.users
  for update using (auth.uid() = id) with check (auth.uid() = id);

-- ---------- LICENSES (só leitura; escrita é do webhook via service_role) ----------
drop policy if exists licenses_select_own on public.licenses;
create policy licenses_select_own on public.licenses
  for select using (auth.uid() = user_id);

-- ---------- SALES / FOLLOWERS / NOTIFICATIONS / AI_MODELS / LIVES ----------
drop policy if exists sales_own on public.sales;
create policy sales_own on public.sales
  for all using (auth.uid() = user_id) with check (auth.uid() = user_id);
drop policy if exists followers_own on public.followers;
create policy followers_own on public.followers
  for all using (auth.uid() = user_id) with check (auth.uid() = user_id);
drop policy if exists notifications_own on public.notifications;
create policy notifications_own on public.notifications
  for all using (auth.uid() = user_id) with check (auth.uid() = user_id);
drop policy if exists ai_models_own on public.ai_models;
create policy ai_models_own on public.ai_models
  for all using (auth.uid() = user_id) with check (auth.uid() = user_id);
drop policy if exists lives_own on public.lives;
create policy lives_own on public.lives
  for all using (auth.uid() = user_id) with check (auth.uid() = user_id);
drop policy if exists prompt_fav_own on public.prompt_favorites;
create policy prompt_fav_own on public.prompt_favorites
  for all using (auth.uid() = user_id) with check (auth.uid() = user_id);
drop policy if exists prompt_usage_own on public.prompt_usage;
create policy prompt_usage_own on public.prompt_usage
  for all using (auth.uid() = user_id) with check (auth.uid() = user_id);
drop policy if exists product_fav_own on public.product_favorites;
create policy product_fav_own on public.product_favorites
  for all using (auth.uid() = user_id) with check (auth.uid() = user_id);
drop policy if exists lesson_progress_own on public.lesson_progress;
create policy lesson_progress_own on public.lesson_progress
  for all using (auth.uid() = user_id) with check (auth.uid() = user_id);

-- ---------- CONTEÚDO (produtos, prompts, aulas) ----------
-- só quem tem licença ativa lê; prompts respeitam o plano mínimo
drop policy if exists products_read on public.products;
create policy products_read on public.products
  for select using (active and public.has_active_license());

drop policy if exists prompts_read on public.prompts;
create policy prompts_read on public.prompts
  for select using (public.has_active_license() and public.plan_covers(min_plan));

drop policy if exists lessons_read on public.lessons;
create policy lessons_read on public.lessons
  for select using (public.plan_covers('pro'));   -- Método 2K: Pro e Lifetime

-- ---------- RANKING (público entre assinantes) ----------
drop policy if exists ranking_read on public.community_ranking;
create policy ranking_read on public.community_ranking
  for select using (public.has_active_license());

-- Observação: a service_role (usada pelas Edge Functions) ignora RLS.
-- É ela quem escreve licenses, products, prompts e lessons.

-- ============================================================
-- 8. WEBHOOKS DA CAKTO
-- ============================================================

-- 8.1 log de eventos (idempotência: o mesmo evento nunca processa duas vezes)
create table if not exists public.cakto_events (
  id           uuid primary key default gen_random_uuid(),
  event_id     text unique not null,
  event_type   text not null,
  order_id     text,
  customer_email citext,
  payload      jsonb not null,
  processed    boolean not null default false,
  error        text,
  received_at  timestamptz not null default now(),
  processed_at timestamptz
);
create index if not exists idx_cakto_events_order on public.cakto_events (order_id);
alter table public.cakto_events enable row level security;  -- só service_role acessa

-- 8.2 mapa de ofertas da Cakto -> plano do PromptVerse
create table if not exists public.cakto_offers (
  offer_id  text primary key,     -- id da oferta na Cakto
  plan      plan_type not null,
  months    integer,              -- null = vitalício
  label     text
);

insert into public.cakto_offers (offer_id, plan, months, label) values
  ('SUBSTITUA_STARTER',  'starter', 1,    'Starter R$ 97/mês'),
  ('SUBSTITUA_PRO',      'pro',     1,    'Pro R$ 197/mês'),
  ('SUBSTITUA_LIFETIME', 'lifetime', null,'Lifetime R$ 297')
on conflict (offer_id) do nothing;

-- 8.3 processa a compra: cria/renova licença e avisa o usuário
--     Chamada pela Edge Function com service_role.
create or replace function public.process_cakto_purchase(
  p_event_id   text,
  p_event_type text,
  p_order_id   text,
  p_email      citext,
  p_offer_id   text,
  p_payload    jsonb
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_user_id uuid;
  v_plan    plan_type;
  v_months  integer;
  v_expires timestamptz;
  v_key     text;
begin
  -- idempotência
  insert into public.cakto_events (event_id, event_type, order_id, customer_email, payload)
  values (p_event_id, p_event_type, p_order_id, p_email, p_payload)
  on conflict (event_id) do nothing;

  if exists (select 1 from public.cakto_events where event_id = p_event_id and processed) then
    return jsonb_build_object('status','already_processed');
  end if;

  select plan, months into v_plan, v_months
    from public.cakto_offers where offer_id = p_offer_id;

  if v_plan is null then
    update public.cakto_events set error = 'oferta desconhecida: '||p_offer_id
     where event_id = p_event_id;
    return jsonb_build_object('status','unknown_offer');
  end if;

  select id into v_user_id from public.users where email = p_email;

  -- usuário ainda não existe: a Edge Function cria no Auth e chama de novo
  if v_user_id is null then
    return jsonb_build_object('status','user_not_found','email',p_email);
  end if;

  -- reembolso / cancelamento
  if p_event_type in ('refund','chargeback','subscription_canceled') then
    update public.licenses
       set status = case p_event_type when 'subscription_canceled' then 'canceled' else 'refunded' end,
           updated_at = now()
     where user_id = v_user_id and status = 'active';

    update public.cakto_events set processed = true, processed_at = now() where event_id = p_event_id;
    return jsonb_build_object('status','revoked');
  end if;

  -- compra aprovada / renovação
  v_expires := case when v_months is null then null else now() + (v_months || ' months')::interval end;

  update public.licenses
     set expires_at = case when v_months is null then null
                           else greatest(coalesce(expires_at, now()), now()) + (v_months||' months')::interval end,
         status = 'active', plan = v_plan, order_id = p_order_id, updated_at = now()
   where user_id = v_user_id and plan = v_plan and status in ('active','expired')
   returning license_key into v_key;

  if v_key is null then
    insert into public.licenses (user_id, plan, expires_at, order_id, status)
    values (v_user_id, v_plan, v_expires, p_order_id, 'active')
    returning license_key into v_key;
  end if;

  insert into public.notifications (user_id, title, message, type)
  values (v_user_id, 'Acesso liberado',
          'Seu plano '||v_plan||' está ativo. Chave de acesso: '||v_key, 'info');

  update public.cakto_events set processed = true, processed_at = now() where event_id = p_event_id;

  return jsonb_build_object('status','ok','license_key',v_key,'plan',v_plan,'user_id',v_user_id);
end $$;

revoke all on function public.process_cakto_purchase(text,text,text,citext,text,jsonb) from public, anon, authenticated;

-- 8.4 validação da chave no login (opcional, além do e-mail + senha)
create or replace function public.validate_license_key(p_key text)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from public.licenses
     where license_key = upper(trim(p_key))
       and user_id = auth.uid()
       and status = 'active'
       and (expires_at is null or expires_at > now())
  );
$$;

-- 8.5 job diário: expira licenças vencidas (agende no Supabase Cron)
create or replace function public.expire_licenses()
returns void language sql security definer set search_path = public as $$
  update public.licenses
     set status = 'expired', updated_at = now()
   where status = 'active'
     and expires_at is not null
     and expires_at < now();
$$;

-- ============================================================
-- 9. VIEW DO DASHBOARD
-- ============================================================
create or replace view public.v_dashboard as
select
  u.id as user_id,
  coalesce((select sum(gmv)        from public.sales s where s.user_id = u.id and s.status='approved'),0) as gmv_total,
  coalesce((select sum(commission) from public.sales s where s.user_id = u.id and s.status='approved'),0) as commission_total,
  coalesce((select count(*)        from public.sales s where s.user_id = u.id and s.status='approved'),0) as sales_count,
  (select followers_count from public.followers f where f.user_id = u.id order by snapshot_date desc limit 1) as followers_current
from public.users u
where u.id = auth.uid();

-- ============================================================
-- 10. SEED DAS AULAS DO MÉTODO 2K
-- ============================================================
insert into public.lessons (number, title, description, duration) values
 (1,'Configuração da conta','Foto, nome de usuário, bio e conta profissional.','9 min'),
 (2,'Escolha de nicho','Cruzar o que você aguenta gravar com o que paga bem.','12 min'),
 (3,'Estratégias orgânicas','Ritmo de postagem e os primeiros 30 dias.','15 min'),
 (4,'Vídeos virais','Hook, corte e retenção nos 3 primeiros segundos.','18 min'),
 (5,'Produtos vencedores','Preço, comissão, prova social e sazonalidade.','14 min'),
 (6,'Escala de conteúdo','Gravar em lote e manter constância.','13 min'),
 (7,'Ativação TikTok Shop','Requisitos, verificação e erros que travam a loja.','11 min'),
 (8,'Monetização','Comissão, campanhas, amostras e leitura do painel.','16 min')
on conflict (number) do nothing;

-- ============================================================
-- FIM
-- ============================================================
