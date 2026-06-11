-- =====================================================================
-- OnTime ‧ 共享行事曆  Supabase schema
-- 套用：Supabase SQL Editor 貼上執行。與 profiles 表（三系統共用）對齊。
-- 認證：公司一律用 @teicomposite.com email（Supabase Auth OTP / magic link），
--       非公司網域帳號禁止登入；正式版以 auth.uid() + RLS 控管。
-- =====================================================================

-- 依賴：已存在 public.profiles(id uuid pk, name, en_name, role, email, ...)（PMSYS/ProjFlow/RTM 共用）

-- ---- 日曆 ----
create table if not exists public.calendars (
  id          text primary key,
  name        text not null,
  color       text not null default '#E8740C',
  owner_id    uuid not null references public.profiles(id),
  created_at  timestamptz not null default now()
);

-- ---- 日曆成員與權限 ----
create table if not exists public.calendar_members (
  calendar_id text not null references public.calendars(id) on delete cascade,
  user_id     uuid not null references public.profiles(id) on delete cascade,
  role        text not null default 'editor' check (role in ('owner','editor','viewer')),
  added_at    timestamptz not null default now(),
  primary key (calendar_id, user_id)
);

-- ---- 行程事件 ----
create table if not exists public.events (
  id           text primary key,
  calendar_id  text not null references public.calendars(id) on delete cascade,
  title        text not null,
  starts_at    timestamptz not null,
  ends_at      timestamptz not null,
  all_day      boolean not null default false,
  color        text default '',                     -- 行程自訂顏色標籤（空=跟隨日曆色）
  location     text default '',
  url          text default '',
  notes        text default '',
  repeat       text not null default 'none' check (repeat in ('none','daily','weekly','monthly','yearly')),
  repeat_until date,
  alerts       int[] not null default '{}',         -- 多組提醒（提前分鐘數）
  attendees    uuid[] not null default '{}',
  attendance   jsonb not null default '{}',         -- { user_id: 'going'|'maybe'|'no' }
  created_by   uuid not null references public.profiles(id),
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now()
);
create index if not exists events_cal_idx   on public.events(calendar_id);
create index if not exists events_start_idx  on public.events(starts_at);

-- ---- 動態（活動 + 聊天合流，TimeTree 的 Feed）----
create table if not exists public.calendar_feed (
  id          text primary key,
  calendar_id text not null references public.calendars(id) on delete cascade,
  user_id     uuid not null references public.profiles(id),
  kind        text not null check (kind in ('act','msg')),     -- act=系統活動, msg=聊天訊息
  action      text check (action in ('create','edit','delete','invite','comment')),
  target      text,
  body        text,
  cross_id    text,                                            -- 跨系統穩定 ID（三邊已讀/回覆對齊）
  created_at  timestamptz not null default now()
);
create index if not exists feed_cal_idx on public.calendar_feed(calendar_id, created_at);

-- ---- Keep（共享備忘 / 連結，不綁日期）----
create table if not exists public.keep (
  id          text primary key,
  calendar_id text not null references public.calendars(id) on delete cascade,
  type        text not null default 'memo' check (type in ('memo','link')),
  title       text not null,
  body        text default '',
  url         text default '',
  pinned      boolean not null default false,
  user_id     uuid not null references public.profiles(id),
  created_at  timestamptz not null default now()
);
create index if not exists keep_cal_idx on public.keep(calendar_id);

-- ---- 行程留言（每個事件底下的對話串，TimeTree 行程留言）----
create table if not exists public.event_comments (
  id         text primary key,
  event_id   text not null references public.events(id) on delete cascade,
  user_id    uuid not null references public.profiles(id),
  text       text not null,
  cross_id   text,                                  -- 跨系統穩定 ID
  created_at timestamptz not null default now()
);
create index if not exists ecmt_event_idx on public.event_comments(event_id);

-- ---- 推播訂閱（Web Push / VAPID）----
create table if not exists public.push_subscriptions (
  user_id    uuid not null references public.profiles(id) on delete cascade,
  endpoint   text primary key,
  p256dh     text not null,
  auth       text not null,
  created_at timestamptz not null default now()
);

-- =====================================================================
-- 只允許公司網域登入：在 Supabase Auth 觸發器擋掉非 @teicomposite.com
-- =====================================================================
create or replace function public.enforce_company_domain()
returns trigger language plpgsql security definer as $$
begin
  if new.email is null or lower(split_part(new.email,'@',2)) <> 'teicomposite.com' then
    raise exception '僅限 @teicomposite.com 公司帳號登入';
  end if;
  return new;
end; $$;
drop trigger if exists trg_company_domain on auth.users;
create trigger trg_company_domain before insert on auth.users
  for each row execute function public.enforce_company_domain();

-- =====================================================================
-- Row Level Security：成員才看得到日曆內容；editor/owner 才可寫
-- =====================================================================
alter table public.calendars        enable row level security;
alter table public.calendar_members enable row level security;
alter table public.events           enable row level security;
alter table public.calendar_feed    enable row level security;
alter table public.keep             enable row level security;
alter table public.event_comments   enable row level security;

create or replace function public.is_member(cal text)
returns boolean language sql security definer stable as $$
  select exists(select 1 from public.calendar_members m where m.calendar_id = cal and m.user_id = auth.uid());
$$;
create or replace function public.can_write(cal text)
returns boolean language sql security definer stable as $$
  select exists(select 1 from public.calendar_members m where m.calendar_id = cal and m.user_id = auth.uid() and m.role in ('owner','editor'));
$$;

create policy cal_read   on public.calendars for select using (public.is_member(id));
create policy cal_insert on public.calendars for insert with check (owner_id = auth.uid());
create policy cal_update on public.calendars for update using (owner_id = auth.uid());

create policy mem_read   on public.calendar_members for select using (public.is_member(calendar_id));
create policy mem_write  on public.calendar_members for all
  using (exists(select 1 from public.calendars c where c.id = calendar_id and c.owner_id = auth.uid()))
  with check (exists(select 1 from public.calendars c where c.id = calendar_id and c.owner_id = auth.uid()));

create policy ev_read   on public.events for select using (public.is_member(calendar_id));
create policy ev_write  on public.events for all using (public.can_write(calendar_id)) with check (public.can_write(calendar_id));

create policy feed_read  on public.calendar_feed for select using (public.is_member(calendar_id));
create policy feed_write on public.calendar_feed for insert with check (public.is_member(calendar_id) and user_id = auth.uid());

create policy keep_read  on public.keep for select using (public.is_member(calendar_id));
create policy keep_write on public.keep for all using (public.can_write(calendar_id)) with check (public.can_write(calendar_id));

create policy ecmt_read  on public.event_comments for select
  using (exists(select 1 from public.events e where e.id = event_id and public.is_member(e.calendar_id)));
create policy ecmt_write on public.event_comments for insert with check (user_id = auth.uid());

-- realtime：即時多人同步
-- alter publication supabase_realtime add table public.events, public.calendar_feed, public.keep;
