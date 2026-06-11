-- =====================================================================
-- TEiTime ‧ 共享行事曆  Supabase schema
-- 套用：Supabase SQL Editor 貼上執行。與 profiles 表（三系統共用）對齊。
-- 正式版：URL 明碼身份僅原型；上線改用 Supabase Auth session / 簽章 JWT。
-- =====================================================================

-- 依賴：已存在 public.profiles(id uuid pk, name, en_name, role, ...)（PMSYS/ProjFlow/RTM 共用）

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
  location     text default '',
  notes        text default '',
  reminder_min int,                          -- null = 不提醒
  created_by   uuid not null references public.profiles(id),
  attendees    uuid[] not null default '{}',
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now()
);
create index if not exists events_cal_idx   on public.events(calendar_id);
create index if not exists events_start_idx  on public.events(starts_at);

-- ---- 事件留言（cross_id 與 PMSYS/ProjFlow/RTM 訊息中心一致）----
create table if not exists public.event_comments (
  id         text primary key,
  event_id   text not null references public.events(id) on delete cascade,
  user_id    uuid not null references public.profiles(id),
  body       text not null,
  cross_id   text,                            -- 跨系統穩定 ID（已讀/回覆/@提及 三邊對齊）
  created_at timestamptz not null default now()
);
create index if not exists comments_event_idx on public.event_comments(event_id);

-- ---- 動態消息 ----
create table if not exists public.calendar_feed (
  id          bigint generated always as identity primary key,
  calendar_id text references public.calendars(id) on delete cascade,
  actor_id    uuid not null references public.profiles(id),
  action      text not null check (action in ('create','edit','delete','comment','invite')),
  target      text,
  body        text,
  created_at  timestamptz not null default now()
);

-- ---- 推播訂閱（Web Push / VAPID）----
create table if not exists public.push_subscriptions (
  user_id    uuid not null references public.profiles(id) on delete cascade,
  endpoint   text primary key,
  p256dh     text not null,
  auth       text not null,
  created_at timestamptz not null default now()
);

-- =====================================================================
-- Row Level Security：成員才看得到日曆內容；editor/owner 才可寫
-- =====================================================================
alter table public.calendars        enable row level security;
alter table public.calendar_members enable row level security;
alter table public.events           enable row level security;
alter table public.event_comments   enable row level security;
alter table public.calendar_feed    enable row level security;

create or replace function public.is_member(cal text)
returns boolean language sql security definer stable as $$
  select exists(select 1 from public.calendar_members m
    where m.calendar_id = cal and m.user_id = auth.uid());
$$;
create or replace function public.can_write(cal text)
returns boolean language sql security definer stable as $$
  select exists(select 1 from public.calendar_members m
    where m.calendar_id = cal and m.user_id = auth.uid() and m.role in ('owner','editor'));
$$;

-- calendars：成員可讀；owner 可改
create policy cal_read   on public.calendars for select using (public.is_member(id));
create policy cal_insert on public.calendars for insert with check (owner_id = auth.uid());
create policy cal_update on public.calendars for update using (owner_id = auth.uid());

-- members：同日曆成員可讀；owner 可管理
create policy mem_read   on public.calendar_members for select using (public.is_member(calendar_id));
create policy mem_write  on public.calendar_members for all
  using (exists(select 1 from public.calendars c where c.id = calendar_id and c.owner_id = auth.uid()))
  with check (exists(select 1 from public.calendars c where c.id = calendar_id and c.owner_id = auth.uid()));

-- events：成員可讀；可寫者可增刪改
create policy ev_read   on public.events for select using (public.is_member(calendar_id));
create policy ev_write  on public.events for all using (public.can_write(calendar_id)) with check (public.can_write(calendar_id));

-- comments：成員可讀，成員可留言（本人）
create policy cmt_read   on public.event_comments for select
  using (exists(select 1 from public.events e where e.id = event_id and public.is_member(e.calendar_id)));
create policy cmt_write  on public.event_comments for insert with check (user_id = auth.uid());

-- feed：日曆成員可讀
create policy feed_read  on public.calendar_feed for select using (calendar_id is null or public.is_member(calendar_id));

-- realtime：把這些表加入 supabase_realtime publication 即可即時多人同步
-- alter publication supabase_realtime add table public.events, public.event_comments, public.calendar_feed;
