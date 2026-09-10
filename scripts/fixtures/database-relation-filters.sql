CREATE SCHEMA relation_filters;
CREATE TABLE relation_filters.account (id bigint PRIMARY KEY, slug text NOT NULL);
CREATE TABLE relation_filters.organization (
    id bigint PRIMARY KEY,
    slug text NOT NULL,
    "accountId" bigint REFERENCES relation_filters.account,
    active boolean DEFAULT false
);
CREATE TABLE relation_filters.member (
    id bigint PRIMARY KEY,
    "organizationId" bigint REFERENCES relation_filters.organization,
    name text NOT NULL
);
INSERT INTO relation_filters.account VALUES (1, 'north'), (2, 'south');
INSERT INTO relation_filters.organization VALUES
    (10, 'sample-studio', 1, true),
    (20, 'other-studio', 2, false),
    (30, E'50%_off\\offer', 1, false);
INSERT INTO relation_filters.member VALUES
    (1, 10, 'Alex Sample'),
    (2, 20, 'Sam Example'),
    (3, 10, 'Taylor Demo'),
    (4, NULL, 'No Organization'),
    (5, 30, 'Special Text');
CREATE TABLE relation_filters.assignment (
    id bigint PRIMARY KEY,
    "ownerId" bigint REFERENCES relation_filters.organization,
    "reviewerId" bigint REFERENCES relation_filters.organization
);
INSERT INTO relation_filters.assignment VALUES (1, 10, 20);
CREATE TABLE relation_filters.composite_org (tenant bigint, id bigint, slug text, PRIMARY KEY (tenant, id));
CREATE TABLE relation_filters.composite_member (
    id bigint PRIMARY KEY, tenant bigint, org bigint,
    FOREIGN KEY (tenant, org) REFERENCES relation_filters.composite_org(tenant, id)
);
INSERT INTO relation_filters.composite_org VALUES (1, 10, 'sample'), (2, 10, 'other');
INSERT INTO relation_filters.composite_member VALUES (1, 1, 10), (2, 2, 10);
CREATE TYPE relation_filters.member_role AS ENUM ('viewer', 'editor', 'admin');
CREATE TABLE relation_filters.enrollment (
    id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    name text NOT NULL DEFAULT 'Sample Member',
    role relation_filters.member_role DEFAULT 'viewer',
    active boolean NOT NULL DEFAULT true,
    settings jsonb DEFAULT '{}'::jsonb
);
INSERT INTO relation_filters.enrollment (name, role) VALUES ('Alex Sample', 'viewer');
