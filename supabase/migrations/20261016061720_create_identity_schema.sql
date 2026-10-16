CREATE TABLE public.organizations (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    name text NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE public.users (
    id uuid PRIMARY KEY,
    organization_id uuid NOT NULL,
    email text NOT NULL,
    full_name text NOT NULL,
    is_active boolean NOT NULL DEFAULT true,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT users_auth_user_fk
        FOREIGN KEY (id)
        REFERENCES auth.users (id)
        ON DELETE RESTRICT
        ON UPDATE RESTRICT,

    CONSTRAINT users_organization_fk
        FOREIGN KEY (organization_id)
        REFERENCES public.organizations (id)
        ON DELETE RESTRICT
        ON UPDATE RESTRICT,

    CONSTRAINT users_id_organization_unique
        UNIQUE (id, organization_id)
);

CREATE UNIQUE INDEX users_email_lower_unique
    ON public.users (lower(email));

CREATE INDEX users_organization_idx
    ON public.users (organization_id);

ALTER TABLE public.organizations ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.users ENABLE ROW LEVEL SECURITY;

CREATE TABLE public.brands (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id uuid NOT NULL,
    name text NOT NULL,
    slug text NOT NULL,
    is_active boolean NOT NULL DEFAULT true,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT brands_organization_fk
        FOREIGN KEY (organization_id)
        REFERENCES public.organizations (id)
        ON DELETE RESTRICT
        ON UPDATE RESTRICT,

    CONSTRAINT brands_id_organization_unique
        UNIQUE (id, organization_id),

    CONSTRAINT organization_id_name_unique
        UNIQUE (organization_id, name),

    CONSTRAINT brands_slug_format_check
        CHECK (slug ~ '^[a-z0-9]+(-[a-z0-9]+)*$')
);

CREATE UNIQUE INDEX brands_slug_unique
    ON public.brands (slug);

ALTER TABLE public.brands ENABLE ROW LEVEL SECURITY;

CREATE TABLE public.roles (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    key text NOT NULL,
    name text NOT NULL,
    description text,
    scope text NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT role_id_scope_unique
        UNIQUE (id, scope),

    CONSTRAINT scope_value_check
        CHECK (scope IN ('organization', 'brand', 'location')),

    CONSTRAINT roles_key_format_check
        CHECK (key ~ '^[a-z]+(_[a-z]+)*$')
);

CREATE UNIQUE INDEX roles_key_unique
    ON public.roles (key);

ALTER TABLE public.roles ENABLE ROW LEVEL SECURITY;

CREATE TABLE public.permissions (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    key text NOT NULL,
    description text NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT permissions_key_format_check
        CHECK (key ~ '^[a-z_]+\.[a-z_]+$')
);

CREATE UNIQUE INDEX permission_key_unique
    ON public.permissions (key);

ALTER TABLE public.permissions ENABLE ROW LEVEL SECURITY;

CREATE TABLE public.locations (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    brand_id uuid NOT NULL,
    store_number text,
    name text NOT NULL,
    address_line1 text,
    city text,
    state text,
    postal_code text,
    timezone text NOT NULL,
    is_active boolean NOT NULL DEFAULT true,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT location_id_brand_unique
        UNIQUE (id, brand_id),

    CONSTRAINT location_brand_id_store_number_unique
        UNIQUE (brand_id, store_number),

    CONSTRAINT locations_brands_fks
        FOREIGN KEY (brand_id)
        REFERENCES public.brands (id)
        ON DELETE RESTRICT
        ON UPDATE RESTRICT
);

ALTER TABLE public.locations ENABLE ROW LEVEL SECURITY;

CREATE TABLE public.user_roles (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id uuid NOT NULL,
    organization_id uuid NOT NULL,
    role_id uuid NOT NULL,
    role_scope text NOT NULL,
    brand_id uuid,
    created_at timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT user_roles_assignment_unique
        UNIQUE NULLS NOT DISTINCT (user_id, role_id, brand_id),

    CONSTRAINT user_roles_scope_check
        CHECK (role_scope IN ('organization', 'brand')),

    CONSTRAINT user_roles_brand_scope_check
        CHECK (
            (role_scope = 'organization' AND brand_id IS NULL)
            OR
            (role_scope = 'brand' AND brand_id IS NOT NULL)
        ),


    CONSTRAINT user_roles_users_fks
        FOREIGN KEY (user_id, organization_id)
        REFERENCES public.users (id, organization_id)
        ON DELETE CASCADE
        ON UPDATE RESTRICT,

    CONSTRAINT user_roles_brands_fks
        FOREIGN KEY (brand_id, organization_id)
        REFERENCES public.brands (id, organization_id)
        ON DELETE RESTRICT
        ON UPDATE RESTRICT,

    CONSTRAINT user_roles_organizations_fks
        FOREIGN KEY (organization_id)
        REFERENCES public.organizations (id)
        ON DELETE RESTRICT
        ON UPDATE RESTRICT,

    CONSTRAINT user_roles_roles_fks
        FOREIGN KEY (role_id, role_scope)
        REFERENCES public.roles (id, scope)
        ON DELETE RESTRICT
        ON UPDATE RESTRICT
);

CREATE INDEX user_roles_user_organization_idx
    ON public.user_roles (user_id, organization_id);

CREATE INDEX user_roles_brand_organization_idx
    ON public.user_roles (brand_id, organization_id);

CREATE INDEX user_roles_role_scope_idx
    ON public.user_roles (role_id, role_scope);

CREATE INDEX user_roles_organization_idx
    ON public.user_roles (organization_id);

ALTER TABLE public.user_roles ENABLE ROW LEVEL SECURITY;

CREATE TABLE public.user_locations (
    user_id uuid NOT NULL,
    location_id uuid NOT NULL,
    organization_id uuid NOT NULL,
    brand_id uuid NOT NULL,
    role_id uuid NOT NULL,
    role_scope text NOT NULL DEFAULT 'location',
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT user_location_PK
        PRIMARY KEY (user_id, location_id),

    CONSTRAINT user_locations_users_fk
        FOREIGN KEY (user_id, organization_id)
        REFERENCES public.users(id, organization_id)
        ON DELETE CASCADE
        ON UPDATE RESTRICT,

    CONSTRAINT user_locations_brands_fk
        FOREIGN KEY (brand_id, organization_id)
        REFERENCES public.brands(id, organization_id)
        ON DELETE RESTRICT
        ON UPDATE RESTRICT,

    CONSTRAINT user_locations_locations_fk
        FOREIGN KEY (location_id, brand_id)
        REFERENCES public.locations(id, brand_id)
        ON DELETE CASCADE
        ON UPDATE RESTRICT,

    CONSTRAINT user_locations_roles_fk
        FOREIGN KEY (role_id, role_scope)
        REFERENCES public.roles (id, scope)
        ON DELETE RESTRICT
        ON UPDATE RESTRICT,

    CONSTRAINT user_locations_organization_fk
        FOREIGN KEY (organization_id)
        REFERENCES public.organizations (id)
        ON DELETE RESTRICT
        ON UPDATE RESTRICT,

    CONSTRAINT user_locations_role_scope_check
        CHECK (role_scope IN ('location'))
);

CREATE INDEX user_locations_user_organization_idx
    ON public.user_locations (user_id, organization_id);

CREATE INDEX user_locations_brand_organization_idx
    ON public.user_locations (brand_id, organization_id);

CREATE INDEX user_locations_location_brand_idx
    ON public.user_locations (location_id, brand_id);

CREATE INDEX user_locations_role_scope_idx
    ON public.user_locations (role_id, role_scope);

CREATE INDEX user_locations_organization_idx
    ON public.user_locations (organization_id);

ALTER TABLE public.user_locations ENABLE ROW LEVEL SECURITY;

CREATE TABLE public.role_permissions (
    role_id uuid NOT NULL,
    permission_id uuid NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT role_permissions_pk
        PRIMARY KEY (role_id, permission_id),

    CONSTRAINT role_permissions_roles_fk
        FOREIGN KEY (role_id)
        REFERENCES public.roles (id)
        ON DELETE CASCADE
        ON UPDATE RESTRICT,

    CONSTRAINT role_permissions_permissions_fk
        FOREIGN KEY (permission_id)
        REFERENCES public.permissions (id)
        ON DELETE CASCADE
        ON UPDATE RESTRICT
);

CREATE INDEX role_permissions_permission_id_idx
    ON public.role_permissions (permission_id);

ALTER TABLE public.role_permissions ENABLE ROW LEVEL SECURITY;

CREATE FUNCTION public.set_updated_at()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = ''
AS $$
BEGIN
    NEW.updated_at := now();
    RETURN NEW;
END;
$$;

CREATE TRIGGER organizations_set_updated_at
BEFORE UPDATE ON public.organizations
FOR EACH ROW
EXECUTE FUNCTION public.set_updated_at();

CREATE TRIGGER users_set_updated_at
BEFORE UPDATE ON public.users
FOR EACH ROW
EXECUTE FUNCTION public.set_updated_at();

CREATE TRIGGER brands_set_updated_at
BEFORE UPDATE ON public.brands
FOR EACH ROW
EXECUTE FUNCTION public.set_updated_at();

CREATE TRIGGER locations_set_updated_at
BEFORE UPDATE ON public.locations
FOR EACH ROW
EXECUTE FUNCTION public.set_updated_at();

CREATE TRIGGER roles_set_updated_at
BEFORE UPDATE ON public.roles
FOR EACH ROW
EXECUTE FUNCTION public.set_updated_at();

CREATE TRIGGER user_locations_set_updated_at
BEFORE UPDATE ON public.user_locations
FOR EACH ROW
EXECUTE FUNCTION public.set_updated_at();