CREATE TABLE public.backup_probe (
    id integer PRIMARY KEY,
    value text NOT NULL
);

INSERT INTO public.backup_probe (id, value) VALUES (1, 'backup-ok');
