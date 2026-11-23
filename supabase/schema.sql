-- =====================================================================
-- FH Cardápio — recriação do banco (Supabase)
-- Cole tudo no SQL Editor de um projeto novo e clique em "Run".
-- =====================================================================

create extension if not exists "pgcrypto";

-- ---------------------------------------------------------------------
-- Configuração de cada loja (multi-tenant via ?loja=slug)
-- ---------------------------------------------------------------------
create table if not exists lojas_config (
  id                  uuid primary key default gen_random_uuid(),
  slug_loja           text unique not null,
  nome_loja           text not null default 'Minha loja',
  senha_painel        text not null,
  numero_whatsapp     text,                      -- só números: 55DDDNUMERO
  tempo_estimado_min  int  default 30,
  tempo_estimado_max  int  default 50,
  horario_abertura    time default '00:00',
  horario_fechamento  time default '23:59',
  dias_funcionamento  int[] default '{0,1,2,3,4,5,6}',  -- 0 = domingo
  aberto_manual       boolean default true,
  endereco_rua        text,
  endereco_numero     text,
  endereco_bairro     text,
  endereco_complemento text,
  criado_em           timestamptz default now()
);

create table if not exists cardapio_categorias (
  id         uuid primary key default gen_random_uuid(),
  slug_loja  text not null references lojas_config(slug_loja) on delete cascade,
  nome       text not null,
  ordem      int  default 0,
  criado_em  timestamptz default now()
);

create table if not exists cardapio_itens (
  id               uuid primary key default gen_random_uuid(),
  slug_loja        text not null references lojas_config(slug_loja) on delete cascade,
  categoria_id     uuid references cardapio_categorias(id) on delete set null,
  nome             text not null,
  descricao        text default '',
  preco            numeric(10,2) not null default 0,
  imagem_url       text default '',
  disponivel       boolean default true,
  controla_estoque boolean default false,
  estoque          int default 0,
  ordem            int default 0,
  criado_em        timestamptz default now()
);

create table if not exists cardapio_ingredientes (
  id         uuid primary key default gen_random_uuid(),
  slug_loja  text not null references lojas_config(slug_loja) on delete cascade,
  nome       text not null,
  estoque    int  default 0,
  criado_em  timestamptz default now()
);

create table if not exists cardapio_item_ingredientes (
  id               uuid primary key default gen_random_uuid(),
  item_id          uuid not null references cardapio_itens(id) on delete cascade,
  ingrediente_id   uuid not null references cardapio_ingredientes(id) on delete cascade,
  quantidade_usada int  not null default 1
);

create table if not exists cardapio_bairros (
  id            uuid primary key default gen_random_uuid(),
  slug_loja     text not null references lojas_config(slug_loja) on delete cascade,
  nome          text not null,
  taxa_entrega  numeric(10,2) default 0,
  ordem         int default 0
);

create table if not exists cardapio_pedidos (
  id                uuid primary key default gen_random_uuid(),
  slug_loja         text not null references lojas_config(slug_loja) on delete cascade,
  nome_cliente      text,
  telefone_cliente  text,
  tipo_entrega      text,             -- 'entrega' | 'retirada'
  forma_pagamento   text,             -- 'pix' | 'dinheiro' | 'cartao' | 'dividido'
  total             numeric(10,2) default 0,
  taxa_entrega      numeric(10,2) default 0,
  itens             jsonb default '[]',
  observacao        text default '',
  pix_confirmado    boolean default false,
  status            text default 'novo',   -- 'novo' ... 'entregue' | 'cancelado'
  criado_em         timestamptz default now()
);

create table if not exists cardapio_clientes (
  id                   uuid primary key default gen_random_uuid(),
  slug_loja            text not null references lojas_config(slug_loja) on delete cascade,
  telefone             text not null,
  nome                 text,
  endereco_rua         text,
  endereco_numero      text,
  endereco_bairro      text,
  endereco_complemento text,
  total_pedidos        int default 0,
  criado_em            timestamptz default now(),
  atualizado_em        timestamptz default now(),
  unique (slug_loja, telefone)
);

create table if not exists cardapio_avaliacoes (
  id            uuid primary key default gen_random_uuid(),
  slug_loja     text not null references lojas_config(slug_loja) on delete cascade,
  nome_cliente  text,
  nota          int check (nota between 1 and 5),
  comentario    text default '',
  criado_em     timestamptz default now()
);

create index if not exists idx_itens_loja      on cardapio_itens(slug_loja, ordem);
create index if not exists idx_categorias_loja on cardapio_categorias(slug_loja, ordem);
create index if not exists idx_pedidos_loja    on cardapio_pedidos(slug_loja, criado_em desc);
create index if not exists idx_pedidos_tel     on cardapio_pedidos(slug_loja, telefone_cliente);

-- atualizado_em automático nos clientes
create or replace function tocar_atualizado_em() returns trigger
language plpgsql as $$
begin new.atualizado_em := now(); return new; end $$;

drop trigger if exists trg_clientes_atualizado on cardapio_clientes;
create trigger trg_clientes_atualizado before update on cardapio_clientes
for each row execute function tocar_atualizado_em();

-- ---------------------------------------------------------------------
-- Baixa de estoque atômica (chamadas pelo index.html)
-- ---------------------------------------------------------------------
create or replace function decrementar_estoque(item_id uuid, quantidade int)
returns void language plpgsql security definer set search_path = public as $$
begin
  update cardapio_itens i
     set estoque    = greatest(i.estoque - quantidade, 0),
         disponivel = case when i.controla_estoque
                           then greatest(i.estoque - quantidade, 0) > 0
                           else i.disponivel end
   where i.id = decrementar_estoque.item_id
     and i.controla_estoque = true;
end $$;

create or replace function decrementar_ingrediente(ingrediente_id_param uuid, quantidade_param int)
returns void language plpgsql security definer set search_path = public as $$
begin
  update cardapio_ingredientes
     set estoque = greatest(estoque - quantidade_param, 0)
   where id = ingrediente_id_param;
end $$;

grant execute on function decrementar_estoque(uuid, int)       to anon, authenticated;
grant execute on function decrementar_ingrediente(uuid, int)   to anon, authenticated;

-- ---------------------------------------------------------------------
-- Permissões (RLS). O app usa só a chave pública e a senha do painel
-- é conferida no navegador, então o acesso anônimo precisa ser liberado
-- — igual ao banco antigo.
-- ---------------------------------------------------------------------
do $$
declare t text;
begin
  foreach t in array array[
    'lojas_config','cardapio_categorias','cardapio_itens','cardapio_ingredientes',
    'cardapio_item_ingredientes','cardapio_bairros','cardapio_pedidos',
    'cardapio_clientes','cardapio_avaliacoes'
  ] loop
    execute format('alter table %I enable row level security', t);
    execute format('drop policy if exists acesso_publico on %I', t);
    execute format('create policy acesso_publico on %I for all to anon, authenticated using (true) with check (true)', t);
  end loop;
end $$;

-- ---------------------------------------------------------------------
-- Bucket das fotos dos produtos (público para leitura)
-- ---------------------------------------------------------------------
insert into storage.buckets (id, name, public)
values ('cardapio-fotos', 'cardapio-fotos', true)
on conflict (id) do update set public = true;

drop policy if exists "fotos leitura" on storage.objects;
drop policy if exists "fotos envio"   on storage.objects;
drop policy if exists "fotos troca"   on storage.objects;
create policy "fotos leitura" on storage.objects for select to anon, authenticated
  using (bucket_id = 'cardapio-fotos');
create policy "fotos envio" on storage.objects for insert to anon, authenticated
  with check (bucket_id = 'cardapio-fotos');
create policy "fotos troca" on storage.objects for update to anon, authenticated
  using (bucket_id = 'cardapio-fotos');

-- ---------------------------------------------------------------------
-- Loja de demonstração (é a que abre quando o link não tem ?loja=)
-- TROQUE 55DDDNUMERO pelo WhatsApp que recebe os pedidos (só números). Senha do painel: 1234
-- ---------------------------------------------------------------------
insert into lojas_config (slug_loja, nome_loja, senha_painel, numero_whatsapp)
values ('brasa-cia', 'FH Cardápio — Demonstração', '1234', '55DDDNUMERO')
on conflict (slug_loja) do nothing;

with cats as (
  insert into cardapio_categorias (slug_loja, nome, ordem) values
    ('brasa-cia', 'Marmitas', 1),
    ('brasa-cia', 'Acompanhamentos', 2),
    ('brasa-cia', 'Sopas', 3),
    ('brasa-cia', 'Bebidas', 4)
  returning id, nome
)
insert into cardapio_itens (slug_loja, categoria_id, nome, descricao, preco, ordem)
select 'brasa-cia', c.id, v.nome, v.descricao, v.preco, v.ordem
from cats c
join (values
  ('Marmitas',        'Frango grelhado com legumes', 'Peito de frango grelhado, arroz integral, brócolis e cenoura. 350g.', 22.90, 1),
  ('Marmitas',        'Carne de panela',             'Carne de panela desfiada, arroz, feijão e purê de mandioquinha. 400g.', 26.90, 2),
  ('Marmitas',        'Strogonoff de frango',        'Strogonoff cremoso, arroz branco e batata palha à parte. 400g.', 24.90, 3),
  ('Marmitas',        'Escondidinho de carne seca',  'Purê de mandioca gratinado com carne seca acebolada. 350g.', 27.90, 4),
  ('Acompanhamentos', 'Arroz integral',              'Porção de 200g.', 7.90, 1),
  ('Acompanhamentos', 'Legumes no vapor',            'Brócolis, cenoura e abobrinha. 200g.', 9.90, 2),
  ('Acompanhamentos', 'Farofa da casa',              'Farofa de mandioca com bacon. 150g.', 6.90, 3),
  ('Sopas',           'Caldo verde',                 'Batata, couve e calabresa. 500ml.', 19.90, 1),
  ('Sopas',           'Sopa de legumes com frango',  'Legumes da estação e frango desfiado. 500ml.', 18.90, 2),
  ('Bebidas',         'Suco natural de laranja',     '500ml.', 9.90, 1),
  ('Bebidas',         'Água mineral',                '500ml.', 3.90, 2)
) as v(categoria, nome, descricao, preco, ordem) on v.categoria = c.nome;

insert into cardapio_bairros (slug_loja, nome, taxa_entrega, ordem) values
  ('brasa-cia', 'Centro', 5.00, 1),
  ('brasa-cia', 'Cambuí', 7.00, 2),
  ('brasa-cia', 'Taquaral', 8.00, 3);

-- Fotos da demonstração (Unsplash, uso gratuito)
update cardapio_itens as i
set imagem_url = 'https://images.unsplash.com/' || f.foto || '?w=600&h=600&fit=crop&auto=format&q=70'
from (values
  ('Frango grelhado com legumes', 'photo-1762631934518-f75e233413ca'),
  ('Carne de panela', 'photo-1519699788450-ad34386a3bfc'),
  ('Strogonoff de frango', 'photo-1644592219048-5c070fd3c91c'),
  ('Escondidinho de carne seca', 'photo-1777199311086-ec5ff230aefd'),
  ('Arroz integral', 'photo-1502472231352-10142bacaba2'),
  ('Legumes no vapor', 'photo-1578071768923-b3d68573028e'),
  ('Caldo verde', 'photo-1594756202469-9ff9799b2e4e'),
  ('Sopa de legumes com frango', 'photo-1512003867696-6d5ce6835040'),
  ('Suco natural de laranja', 'photo-1600271886742-f049cd451bba'),
  ('Água mineral', 'photo-1616118132534-381148898bb4')
) as f(nome, foto)
where i.nome = f.nome and i.slug_loja = 'brasa-cia';
