------------------------------------------------------------------------------
--                                  G P S                                   --
--                                                                          --
--                     Copyright (C) 2011-2012, AdaCore                     --
--                                                                          --
-- This is free software;  you can redistribute it  and/or modify it  under --
-- terms of the  GNU General Public License as published  by the Free Soft- --
-- ware  Foundation;  either version 3,  or (at your option) any later ver- --
-- sion.  This software is distributed in the hope  that it will be useful, --
-- but WITHOUT ANY WARRANTY;  without even the implied warranty of MERCHAN- --
-- TABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public --
-- License for  more details.  You should have  received  a copy of the GNU --
-- General  Public  License  distributed  with  this  software;   see  file --
-- COPYING3.  If not, go to http://www.gnu.org/licenses for a complete copy --
-- of the license.                                                          --
------------------------------------------------------------------------------

--  This package provides support for parsing the .ali and .gli files that
--  are generated by GNAT and gcc. In particular, those files contain
--  information that can be used to do cross-references for entities (going
--  from references to their declaration for instance).
--
--  A typical example would be:
--
--  declare
--     Session : Session_Type;
--  begin
--     GNATCOLL.SQL.Sessions.Setup
--        (Descr   => GNATCOLL.SQL.Sqlite.Setup (":memory:"));
--     Session := Get_New_Session;
--
--     ... parse the project through GNATCOLL.Projects
--
--     Create_Database (Session.DB);
--     Parse_All_LI_Files (Session, ...);
--   end;

with Ada.Containers.Ordered_Sets;
with Ada.Strings.Unbounded; use Ada.Strings.Unbounded;
with GNAT.Regpat;           use GNAT.Regpat;
with GNAT.Strings;          use GNAT.Strings;
with GNATCOLL.Projects;     use GNATCOLL.Projects;
with GNATCOLL.SQL.Exec;     use GNATCOLL.SQL.Exec;
with GNATCOLL.VFS;

package GNATCOLL.Xref is

   ---------------------------------
   --  Creating the xref database --
   ---------------------------------

   type Xref_Database is tagged private;
   type Xref_Database_Access is access all Xref_Database'Class;

   procedure On_Error
     (Self  : Xref_Database;
      Error : String) is null;
   --  Called whenever an error should be emitted by the operations on this
   --  database. Client applications should inherit from Xref_Database and
   --  redefine this to use their own logging facility.

   procedure Setup_DB
     (Self : in out Xref_Database;
      DB   : not null access
        GNATCOLL.SQL.Exec.Database_Description_Record'Class);
   --  Points to the actual database that will be used to store the xref
   --  information.
   --  This database might contain the information from several projects.
   --  An example:
   --     declare
   --        Xref : Xref_Database;
   --     begin
   --        Xref.Setup_DB
   --          (GNATCOLL.SQL.Sqlite.Setup (":memory:"));
   --     end;

   procedure Free (Self : in out Xref_Database);
   --  Free the memory allocated for Self, and closes the database connection.

   procedure Parse_All_LI_Files
     (Self                : in out Xref_Database;
      Tree                : Project_Tree;
      Project             : Project_Type;
      Parse_Runtime_Files : Boolean := True;
      Show_Progress       : access procedure (Current, Total : Integer);
      From_DB_Name        : String := "";
      To_DB_Name          : String := "");
   --  Parse all the LI files for the project, and stores the xref info in the
   --  DB database.
   --
   --  The database in DB is first initialized by copying the database
   --  from From_DB_Name (if one exists).
   --  When no using sqlite, this procedure cannot initialize a database from
   --  another one. In this case, the database must always have been created
   --  first (through a call to Create_Database).
   --
   --  Show_Progress can be specified if you want to monitor the progress of
   --  the parsing. It will be called for each file.
   --
   --  On exit, the in-memory database is copied back to To_DB_Name if that
   --  file is writable and the parameter is not the empty string.
   --  As such, it is possible to generate an entities database as part of a
   --  nightly build of an application, in a read-only area. Then each user's
   --  database is initially copied from that nightly database, and then can
   --  either be kept in memory (passing "" for To_DB_Name) or dumped back to
   --  a local user-writable file.
   --
   --  In fact, depending on the number of LI files to update, GNATCOLL might
   --  decide to temporarily work in memory. Thus, we have the following
   --  databases involved:
   --      From_DB_Name (e.g. from nightly builds)
   --          |        (copy only if DB doesn't exist yet
   --          v           and is not the same file already)
   --         DB
   --          |
   --          v
   --       :memory:    (if the number of LI files to update is big)
   --          |
   --          v
   --         DB        (overridden after the update in memory, or changed
   --          |         directly)
   --          v
   --      To_DB_Name   (if specified and different from DB)
   --
   --  If DB is an in-memory database, this procedure will be faster
   --  than directly modifying the database on the disk (through a call to
   --  Parse_All_LI_Files) when lots of changes need to be made.
   --  Otherwise, it will be slower since dumping the in-memory database to the
   --  disk is likely to take several seconds.
   --
   --  Parse_Runtime_Files indicates whether we should be looking at the
   --  predefined object directories to find extra ALI files to parse. This
   --  will in general include the Ada runtime.

   -------------
   -- Queries --
   -------------

   type Visible_Column is new Integer;
   --  Columns in this API are related to what the user actually sees, not
   --  characters in the file. This impacts files that contain tabulation
   --  characters. For instance, a file that contains
   --     A :<tab><tab>B;
   --  has A at column 4 and B at column ((7 + 8 * 2) div 8) * 8 => 17, not 9.
   --
   --  As a reminder for this rule, we use a distinct type for column numbers.
   --  Conversion from visible columns to characters requires access to the
   --  source file.

   type Entity_Information is private;
   No_Entity : constant Entity_Information;
   --  The description of an entity.
   --  This entity is independent from the database (ie it remains usable even
   --  if the database has changed since you retrieved the Entity_Information).
   --  However, it might not be pointing to an entity that no longer exists.
   --  This information, however, is only valid as long as the object
   --  Xref_Database hasn't been destroyed.

   type Entity_Reference is record
      Entity : Entity_Information;
      File   : GNATCOLL.VFS.Virtual_File;
      Line   : Integer;
      Column : Visible_Column;
      Kind   : Ada.Strings.Unbounded.Unbounded_String;
      Scope  : Entity_Information;
   end record;
   No_Entity_Reference : constant Entity_Reference;
   --  A reference to an entity, at a given location.

   function Image
     (Self : Xref_Database; File : GNATCOLL.VFS.Virtual_File) return String;
   function Image
     (Self : Xref_Database; Ref : Entity_Reference) return String;
   --  Return a display version of the reference's location.
   --  These subprograms can be overridden if you want to print the full
   --  path name of files (rather than the default base name)

   function Get_Entity
     (Self   : Xref_Database;
      Name   : String;
      File   : String;
      Line   : Integer := -1;
      Column : Visible_Column := -1) return Entity_Reference;
   function Get_Entity
     (Self   : Xref_Database;
      Name   : String;
      File   : GNATCOLL.VFS.Virtual_File;
      Line   : Integer := -1;
      Column : Visible_Column := -1) return Entity_Reference;
   --  Return the entity that has a reference at the given location.
   --  When the file is passed as a string, it is permissible to pass only the
   --  basename (or a string like "partial/path/basename") that will be matched
   --  against all known files in the database.

   function Is_Fuzzy_Match (Self : Entity_Information) return Boolean;
   --  Returns True if the entity that was found is only an approximation,
   --  because no exact match was found. This can happen when sources are
   --  newer than ALI files.

   type Entity_Declaration is record
      Name     : Ada.Strings.Unbounded.Unbounded_String;
      Kind     : Ada.Strings.Unbounded.Unbounded_String;
      Location : Entity_Reference;
      Is_Subprogram : Boolean;
   end record;
   No_Entity_Declaration : constant Entity_Declaration;

   function Declaration
     (Xref   : Xref_Database;
      Entity : Entity_Information) return Entity_Declaration;
   --  Return the name of the entity

   function Is_Predefined_Entity
     (Decl : Entity_Declaration) return Boolean;
   --  Returns True if the corresponding entity is a predefined entity, ie
   --  the location of the declaration is irrelevant (only the name should be
   --  taken into account)

   type Base_Cursor is abstract tagged private;
   function Has_Element (Self : Base_Cursor) return Boolean;
   procedure Next (Self : in out Base_Cursor);

   -------------------
   -- Documentation --
   -------------------
   --  The following subprograms are used to provide documentation on an
   --  entity. Their output is not meant to be parsed by tools (use other
   --  subprograms for this), but to be displayed to the user.
   --  Use the Documentation subprogram if you want to combine the various
   --  pieces of information into a single string.

   type Formatting is (Text, HTML);

   type Language_Syntax is record
      Comment_Start                 : GNAT.Strings.String_Access;
      --  How comments start for this language. This is for comments that
      --  do not end on Newline, but with Comment_End.

      Comment_End                   : GNAT.Strings.String_Access;
      --  How comments end for this language

      New_Line_Comment_Start        : GNAT.Strings.String_Access;
      --  How comments start. These comments end on the next newline
      --  character. If null, use New_Line_Comment_Start_Regexp instead.

      New_Line_Comment_Start_Regexp : access GNAT.Regpat.Pattern_Matcher;
      --  How comments start. These comments end on the next newline
      --  character. If null, use New_Line_Comment_Start instead.
   end record;
   --  Describes the syntax for a programming language. This is used to
   --  extra comments from source files.

   Ada_Syntax : constant Language_Syntax;
   C_Syntax : constant Language_Syntax;
   Cpp_Syntax : constant Language_Syntax;

   function Overview
     (Self   : Xref_Database;
      Entity : Entity_Information;
      Format : Formatting := Text) return String;
   --  Returns a one-line overview of the entity's type.
   --  For instance: "procedure declared at file:line:column" or
   --  "record declared at file:line:column".

   function Extract_Comment
     (Buffer           : String;
      Decl_Start_Index : Integer;
      Decl_End_Index   : Integer;
      Language         : Language_Syntax;
      Format           : Formatting := Text) return String;
   --  Extra comment from the source code, given the range of an entity
   --  declaration. This program is made public so that you can reuse it
   --  if you need to override Comment below, or have other means to get the
   --  information about an entity's location (for instance, in an IDE where
   --  the editor might change and the LI files are not regenerated
   --  immediately).
   --  In this version, the start and end of the declaration are given as
   --  indexes in Buffer.

   function Extract_Comment
     (Buffer            : String;
      Decl_Start_Line   : Integer;
      Decl_Start_Column : Integer;
      Decl_End_Line     : Integer := -1;
      Decl_End_Column   : Integer := -1;
      Language          : Language_Syntax;
      Format            : Formatting := Text) return String;
   --  Same as above, but the scope of the declaration is given as line and
   --  column. By default, the end is on the same position as the start.

   function Comment
     (Self     : Xref_Database;
      Entity   : Entity_Information;
      Language : Language_Syntax;
      Format   : Formatting := Text) return String;
   --  Returns the comment (extracted from the source file) for the entity.
   --  This is looked for just before or just after the declaration of the
   --  entity.

   function Text_Declaration
     (Self   : Xref_Database;
      Entity : Entity_Information;
      Format : Formatting := Text) return String;
   --  Returns a documentation-oriented version of the declaration of the
   --  entity. For a subprogram, for instance, it will include the list of
   --  parameters, their types, the return value,...
   --  The information given here might not match exactly what is found in
   --  the source, given the limited details that are provided by the compilers
   --  in the LI files.
   --  Output example:
   --       Parameters
   --           A : in Integer
   --           B : out String
   --       Return
   --           Integer
   --  or another example:
   --       Type: Unbounded_String

   function Documentation
     (Self     : Xref_Database;
      Entity   : Entity_Information;
      Language : Language_Syntax;
      Format   : Formatting := Text) return String;
   --  Combines the various documentation subprogram output into a single
   --  string.

   function Qualified_Name
     (Self   : Xref_Database;
      Entity : Entity_Information) return String;
   --  Returns the fully qualified name for the entity

   ----------------
   -- References --
   ----------------

   type References_Cursor is new Base_Cursor with private;
   function Element (Self : References_Cursor) return Entity_Reference;

   type Reference_Iterator is not null access procedure
     (Self   : Xref_Database'Class;
      Entity : Entity_Information;
      Cursor : out References_Cursor'Class);

   procedure References
     (Self   : Xref_Database'Class;
      Entity : Entity_Information;
      Cursor : out References_Cursor'Class);
   --  Return all references to the entity

   procedure Bodies
     (Self   : Xref_Database'Class;
      Entity : Entity_Information;
      Cursor : out References_Cursor'Class);
   --  Return the location for the bodies of entities, or their full
   --  declaration in the case of private entities.

   type Recursive_References_Cursor is new References_Cursor with private;
   overriding procedure Next (Self : in out Recursive_References_Cursor);

   procedure Recursive
     (Self            : access Xref_Database'Class;
      Entity          : Entity_Information;
      Compute         : Reference_Iterator;
      Cursor          : out Recursive_References_Cursor'Class;
      From_Overriding : Boolean := True;
      From_Overridden : Boolean := True;
      From_Renames    : Boolean := True);
   --  Execute Compute for Entity and all the entities that override it
   --  (if From_Overriding is True), that are overridden by it (if
   --  From_Overridden is True) or that rename it (if From_Renames is True).
   --
   --  Note that Compute is meant to do the actual computation, so it should
   --  in general be one of the subprograms defined above like References or
   --  Bodies. To get access to the actual list of references, you need to
   --  iterate the Cursor, using Has_Element, Element and Next as usual.
   --
   --  Freeing Self while the cursor exits results in undefined behavior.

   --------------
   -- Entities --
   --------------

   type Entities_Cursor is new Base_Cursor with private;
   function Element (Self : Entities_Cursor) return Entity_Information;

   procedure Calls
     (Self   : Xref_Database'Class;
      Entity : Entity_Information;
      Cursor : out Entities_Cursor'Class);
   --  All entities called by Self

   procedure Callers
     (Self   : Xref_Database'Class;
      Entity : Entity_Information;
      Cursor : out Entities_Cursor'Class);
   --  All entities calling Self

   procedure Child_Types
     (Self   : Xref_Database'Class;
      Entity : Entity_Information;
      Cursor : out Entities_Cursor'Class);
   --  The child types for the entity (for instance the classes derived from
   --  Self).

   procedure Parent_Types
     (Self   : Xref_Database'Class;
      Entity : Entity_Information;
      Cursor : out Entities_Cursor'Class);
   --  The parent types for the entity (for instance the classes or interfaces
   --  from which Self derives).

   procedure Methods
     (Self   : Xref_Database'Class;
      Entity : Entity_Information;
      Cursor : out Entities_Cursor'Class);
   --  The primitive operations (or methods) of Self

   function Method_Of
      (Self   : Xref_Database'Class;
       Entity : Entity_Information) return Entity_Information;
   --  Return the entity (presumably an Ada tagged type or C++ class) for which
   --  Entity is a method or primitive operation.

   function Overrides
     (Self   : Xref_Database'Class;
      Entity : Entity_Information) return Entity_Information;
   --  The entity that is overridden by Entity (ie the method in
   --  the parent class that is overriden by Entity).

   procedure Overridden_By
     (Self   : Xref_Database'Class;
      Entity : Entity_Information;
      Cursor : out Entities_Cursor'Class);
   --  The list of entities that override Entity (in general, methods of
   --  child classes that override Entity).

   function Type_Of
     (Self   : Xref_Database'Class;
      Entity : Entity_Information) return Entity_Information;
   --  Returns the type of the entity (as declared in the sources for variables
   --  and constants, for instance).
   --  For a function, this is the returned type.

   function Component_Type
     (Self   : Xref_Database'Class;
      Entity : Entity_Information) return Entity_Information;
   --  Return the type of the components of Entity (for arrays for instance,
   --  this is the type for elements in the array)

   function Pointed_Type
     (Self   : Xref_Database'Class;
      Entity : Entity_Information) return Entity_Information;
   --  Return the type pointed to by the access/pointer Entity

   function Renaming_Of
     (Self   : Xref_Database'Class;
      Entity : Entity_Information) return Entity_Information;
   --  Returns the entity renamed by Entity (i.e. Entity acts as an alias
   --  for the returned entity)

   type Recursive_Entities_Cursor is new Entities_Cursor with private;
   overriding procedure Next (Self : in out Recursive_Entities_Cursor);

   type Entities_Iterator is not null access procedure
     (Self   : Xref_Database'Class;
      Entity : Entity_Information;
      Cursor : out Entities_Cursor'Class);

   procedure Recursive
     (Self    : access Xref_Database'Class;
      Entity  : Entity_Information;
      Compute : Entities_Iterator;
      Cursor  : out Recursive_Entities_Cursor);
   --  Returns the result of Compute for Entity and all the entities
   --  returned by Compute, recursively. This can for instance be used to
   --  retrieve all classes derived directly or indirectly from Entity, by
   --  passing Child_Types'Access for Compute, or to get all entities called
   --  even indirectly by Entity).

   type Parameter_Kind is
     (In_Parameter,
      Out_Parameter,
      In_Out_Parameter,
      Access_Parameter);
   type Parameter_Information is record
      Parameter : Entity_Information;
      Kind      : Parameter_Kind;
   end record;

   function Image (Kind : Parameter_Kind) return String;
   --  Return a display version of Kind

   type Parameters_Cursor is new Base_Cursor with private;
   function Element (Self : Parameters_Cursor) return Parameter_Information;
   function Parameters
     (Self   : Xref_Database'Class;
      Entity : Entity_Information) return Parameters_Cursor;
   --  Return the list of parameters for the given subprogram. They are in the
   --  same order as in the source.

   -----------
   -- Files --
   -----------

   type Files_Cursor is new Base_Cursor with private;
   function Element (Self : Files_Cursor) return GNATCOLL.VFS.Virtual_File;

   function Importing
     (Self : Xref_Database'Class;
      File : GNATCOLL.VFS.Virtual_File) return Files_Cursor;
   --  Returns the list of files that import (via a "with" statement in Ada,
   --  or a "#include# in C) the parameter File.

   function Imports
     (Self : Xref_Database'Class;
      File : GNATCOLL.VFS.Virtual_File) return Files_Cursor;
   --  Returns the list of files that File depends on directly.

   package File_Sets is new Ada.Containers.Ordered_Sets
     (GNATCOLL.VFS.Virtual_File, GNATCOLL.VFS."<", GNATCOLL.VFS."=");

   function Depends_On
     (Self : Xref_Database'Class;
      File : GNATCOLL.VFS.Virtual_File) return File_Sets.Set;
   --  Returns the list of files that File depends on explicitly or implicitly.

   procedure Referenced_In
     (Self   : Xref_Database'Class;
      File   : GNATCOLL.VFS.Virtual_File;
      Cursor : out Entities_Cursor'Class);
   procedure Referenced_In
     (Self   : Xref_Database'Class;
      File   : GNATCOLL.VFS.Virtual_File;
      Name   : String;
      Cursor : out Entities_Cursor'Class);
   --  Returns the list of all the entities referenced at least once in the
   --  given file. This of course includes entities declared in that file.
   --
   --  A version is given that only returns entities with a given name. It is
   --  for instance useful when Get_Entity returns No_Entity (because there
   --  is no exact reference, nor close-by, for an entity).

private
   type Xref_Database is tagged record
      DB      : GNATCOLL.SQL.Exec.Database_Connection;

      DB_Created : Boolean := False;
      --  Whether we have already created the database (or assumed that it
      --  existed). This is so that running Parse_All_LI_Files multiple times
      --  for an in-memory database does not always try to recreate it
   end record;

   function "<" (E1, E2 : Entity_Information) return Boolean;
   function "=" (E1, E2 : Entity_Information) return Boolean;

   type Entity_Information is record
      Id    : Integer;
      Fuzzy : Boolean := False;
   end record;
   No_Entity : constant Entity_Information :=
     (Id => -1, Fuzzy => True);

   No_Entity_Reference : constant Entity_Reference :=
     (Entity => No_Entity,
      File   => GNATCOLL.VFS.No_File,
      Line   => -1,
      Column => -1,
      Kind   => Ada.Strings.Unbounded.Null_Unbounded_String,
      Scope  => No_Entity);

   No_Entity_Declaration : constant Entity_Declaration :=
     (Name     => Ada.Strings.Unbounded.Null_Unbounded_String,
      Kind     => Ada.Strings.Unbounded.Null_Unbounded_String,
      Location => No_Entity_Reference,
      Is_Subprogram => False);

   package Entity_Sets is new Ada.Containers.Ordered_Sets
     (Entity_Information);

   type Base_Cursor is abstract tagged record
      DBCursor : GNATCOLL.SQL.Exec.Forward_Cursor;
   end record;

   type References_Cursor is new Base_Cursor with record
      Entity : Entity_Information;
   end record;
   type Entities_Cursor is new Base_Cursor with null record;
   type Parameters_Cursor is new Base_Cursor with null record;
   type Files_Cursor is new Base_Cursor with null record;

   type Recursive_References_Cursor is new References_Cursor with record
      Xref            : Xref_Database_Access;
      Compute         : Reference_Iterator := References'Access;
      Visited         : Entity_Sets.Set;
      To_Visit        : Entity_Sets.Set;
      From_Overriding : Boolean;
      From_Overridden : Boolean;
      From_Renames    : Boolean;
   end record;

   type Recursive_Entities_Cursor is new Entities_Cursor with record
      Xref            : Xref_Database_Access;
      Compute         : Entities_Iterator := Calls'Access;
      Visited         : Entity_Sets.Set;
      To_Visit        : Entity_Sets.Set;
   end record;

   Ada_Syntax : constant Language_Syntax :=
     (Comment_Start                 => null,
      Comment_End                   => null,
      New_Line_Comment_Start        => new String'("--"),
      New_Line_Comment_Start_Regexp => null);
   C_Syntax : constant Language_Syntax :=
     (Comment_Start                 => new String'("/*"),
      Comment_End                   => new String'("*/"),
      New_Line_Comment_Start        => new String'("//"),
      New_Line_Comment_Start_Regexp => null);
   Cpp_Syntax : constant Language_Syntax :=
     (Comment_Start                 => new String'("/*"),
      Comment_End                   => new String'("*/"),
      New_Line_Comment_Start        => new String'("//"),
      New_Line_Comment_Start_Regexp => null);
end GNATCOLL.Xref;
