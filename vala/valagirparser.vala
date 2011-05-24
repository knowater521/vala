/* valagirparser.vala
 *
 * Copyright (C) 2008-2010  Jürg Billeter
 * Copyright (C) 2011  Luca Bruno
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Lesser General Public
 * License as published by the Free Software Foundation; either
 * version 2.1 of the License, or (at your option) any later version.

 * This library is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
 * Lesser General Public License for more details.

 * You should have received a copy of the GNU Lesser General Public
 * License along with this library; if not, write to the Free Software
 * Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301  USA
 *
 * Author:
 * 	Jürg Billeter <j@bitron.ch>
 * 	Luca Bruno <lucabru@src.gnome.org>
 */

using GLib;

/**
 * Code visitor parsing all GIR source files.
 *
 * Pipeline:
 * 1) Parse metadata
 * 2) Parse GIR with metadata, track unresolved GIR symbols, create Vala symbols
 * 3) Reconciliate the tree by mapping tracked symbols
 * 4) Process the tree
 */
public class Vala.GirParser : CodeVisitor {
	/*
	 * Metadata parser
	 */

	enum ArgumentType {
		SKIP,
		HIDDEN,
		TYPE,
		TYPE_ARGUMENTS,
		CHEADER_FILENAME,
		NAME,
		OWNED,
		UNOWNED,
		PARENT,
		NULLABLE,
		DEPRECATED,
		REPLACEMENT,
		DEPRECATED_SINCE,
		ARRAY,
		ARRAY_LENGTH_IDX,
		DEFAULT,
		OUT,
		REF,
		VFUNC_NAME,
		VIRTUAL,
		ABSTRACT,
		SCOPE,
		STRUCT,
		THROWS,
		PRINTF_FORMAT;

		public static ArgumentType? from_string (string name) {
			var enum_class = (EnumClass) typeof(ArgumentType).class_ref ();
			var nick = name.replace ("_", "-");
			unowned GLib.EnumValue? enum_value = enum_class.get_value_by_nick (nick);
			if (enum_value != null) {
				ArgumentType value = (ArgumentType) enum_value.value;
				return value;
			}
			return null;
		}
	}

	class Argument {
		public Expression expression;
		public SourceReference source_reference;

		public bool used = false;

		public Argument (Expression expression, SourceReference? source_reference = null) {
			this.expression = expression;
			this.source_reference = source_reference;
		}
	}

	class MetadataSet : Metadata {
		public MetadataSet (string? selector = null) {
			base ("", selector);
		}

		public void add_sibling (Metadata metadata) {
			foreach (var child in metadata.children) {
				add_child (child);
			}
			// merge arguments and take precedence
			foreach (var key in metadata.args.get_keys ()) {
				args[key] = metadata.args[key];
			}
		}
	}

	class Metadata {
		private static Metadata _empty = null;
		public static Metadata empty {
			get {
				if (_empty == null) {
					_empty = new Metadata ("");
				}
				return _empty;
			}
		}

		public PatternSpec pattern_spec;
		public string? selector;
		public SourceReference source_reference;

		public bool used = false;
		public Vala.Map<ArgumentType,Argument> args = new HashMap<ArgumentType,Argument> ();
		public ArrayList<Metadata> children = new ArrayList<Metadata> ();

		public Metadata (string pattern, string? selector = null, SourceReference? source_reference = null) {
			this.pattern_spec = new PatternSpec (pattern);
			this.selector = selector;
			this.source_reference = source_reference;
		}

		public void add_child (Metadata metadata) {
			children.add (metadata);
		}

		public Metadata match_child (string name, string? selector = null) {
			var result = Metadata.empty;
			foreach (var metadata in children) {
				if ((selector == null || metadata.selector == null || metadata.selector == selector) && metadata.pattern_spec.match_string (name)) {
					metadata.used = true;
					if (result == Metadata.empty) {
						// first match
						result = metadata;
					} else {
						var ms = result as MetadataSet;
						if (ms == null) {
							// second match
							ms = new MetadataSet (selector);
							ms.add_sibling (result);
						}
						ms.add_sibling (metadata);
						result = ms;
					}
				}
			}
			return result;
		}

		public void add_argument (ArgumentType key, Argument value) {
			args.set (key, value);
		}

		public bool has_argument (ArgumentType key) {
			return args.contains (key);
		}

		public Expression? get_expression (ArgumentType arg) {
			var val = args.get (arg);
			if (val != null) {
				val.used = true;
				return val.expression;
			}
			return null;
		}

		public string? get_string (ArgumentType arg) {
			var lit = get_expression (arg) as StringLiteral;
			if (lit != null) {
				return lit.eval ();
			}
			return null;
		}

		public int get_integer (ArgumentType arg) {
			var unary = get_expression (arg) as UnaryExpression;
			if (unary != null && unary.operator == UnaryOperator.MINUS) {
				var lit = unary.inner as IntegerLiteral;
				if (lit != null) {
					return -int.parse (lit.value);
				}
			} else {
				var lit = get_expression (arg) as IntegerLiteral;
				if (lit != null) {
					return int.parse (lit.value);
				}
			}

			return 0;
		}

		public bool get_bool (ArgumentType arg) {
			var lit = get_expression (arg) as BooleanLiteral;
			if (lit != null) {
				return lit.value;
			}
			return false;
		}

		public SourceReference? get_source_reference (ArgumentType arg) {
			var val = args.get (arg);
			if (val != null) {
				return val.source_reference;
			}
			return null;
		}
	}

	class MetadataParser {
		/**
		 * Grammar:
		 * metadata ::= [ rule [ '\n' relativerule ]* ]
		 * rule ::= pattern ' ' [ args ]
		 * relativerule ::= '.' rule
		 * pattern ::= glob [ '#' selector ] [ '.' pattern ]
		 */
		private Metadata tree = new Metadata ("");
		private Scanner scanner;
		private SourceLocation begin;
		private SourceLocation end;
		private SourceLocation old_end;
		private TokenType current;
		private Metadata parent_metadata;

		public MetadataParser () {
			tree.used = true;
		}

		SourceReference get_current_src () {
			return new SourceReference (scanner.source_file, begin.line, begin.column, end.line, end.column);
		}

		SourceReference get_src (SourceLocation begin, SourceLocation? end = null) {
			if (end == null) {
				end = this.end;
			}
			return new SourceReference (scanner.source_file, begin.line, begin.column, end.line, end.column);
		}

		public Metadata parse_metadata (SourceFile metadata_file) {
			scanner = new Scanner (metadata_file);
			next ();
			while (current != TokenType.EOF) {
				if (!parse_rule ()) {
					return Metadata.empty;
				}
			}
			return tree;
		}

		TokenType next () {
			old_end = end;
			current = scanner.read_token (out begin, out end);
			return current;
		}

		bool has_space () {
			return old_end.pos != begin.pos;
		}

		bool has_newline () {
			return old_end.line != begin.line;
		}

		string get_string (SourceLocation? begin = null, SourceLocation? end = null) {
			if (begin == null) {
				begin = this.begin;
			}
			if (end == null) {
				end = this.end;
			}
			return ((string) begin.pos).substring (0, (int) (end.pos - begin.pos));
		}

		string? parse_identifier (bool is_glob) {
			var begin = this.begin;

			if (current == TokenType.DOT || current == TokenType.HASH) {
				if (is_glob) {
					Report.error (get_src (begin), "expected glob-style pattern");
				} else {
					Report.error (get_src (begin), "expected identifier");
				}
				return null;
			}

			if (is_glob) {
				while (current != TokenType.EOF && current != TokenType.DOT && current != TokenType.HASH) {
					next ();
					if (has_space ()) {
						break;
					}
				}
			} else {
				next ();
			}

			return get_string (begin, old_end);
		}

		string? parse_selector () {
			if (current != TokenType.HASH || has_space ()) {
				return null;
			}
			next ();

			return parse_identifier (false);
		}

		Metadata? parse_pattern () {
			Metadata metadata;
			bool is_relative = false;
			if (current == TokenType.IDENTIFIER || current == TokenType.STAR) {
				// absolute pattern
				parent_metadata = tree;
			} else {
				// relative pattern
				if (current != TokenType.DOT) {
					Report.error (get_current_src (), "expected pattern or `.', got %s".printf (current.to_string ()));
					return null;
				}
				next ();
				is_relative = true;
			}

			if (parent_metadata == null) {
				Report.error (get_current_src (), "cannot determinate parent metadata");
				return null;
			}

			SourceLocation begin = this.begin;
			var pattern = parse_identifier (true);
			if (pattern == null) {
				return null;
			}
			metadata = new Metadata (pattern, parse_selector (), get_src (begin));
			parent_metadata.add_child (metadata);

			while (current != TokenType.EOF && !has_space ()) {
				if (current != TokenType.DOT) {
					Report.error (get_current_src (), "expected `.' got %s".printf (current.to_string ()));
					break;
				}
				next ();

				begin = this.begin;
				pattern = parse_identifier (true);
				if (pattern == null) {
					return null;
				}
				var child = new Metadata (pattern, parse_selector (), get_src (begin, old_end));
				metadata.add_child (child);
				metadata = child;
			}
			if (!is_relative) {
				parent_metadata = metadata;
			}

			return metadata;
		}

		Expression? parse_expression () {
			var begin = this.begin;
			var src = get_current_src ();
			Expression expr = null;
			switch (current) {
			case TokenType.NULL:
				expr = new NullLiteral (src);
				break;
			case TokenType.TRUE:
				expr = new BooleanLiteral (true, src);
				break;
			case TokenType.FALSE:
				expr = new BooleanLiteral (false, src);
				break;
			case TokenType.MINUS:
				next ();
				var inner = parse_expression ();
				if (inner == null) {
					Report.error (src, "expected expression after `-', got %s".printf (current.to_string ()));
				} else {
					expr = new UnaryExpression (UnaryOperator.MINUS, inner, get_src (begin));
				}
				return expr;
			case TokenType.INTEGER_LITERAL:
				expr = new IntegerLiteral (get_string (), src);
				break;
			case TokenType.REAL_LITERAL:
				expr = new RealLiteral (get_string (), src);
				break;
			case TokenType.STRING_LITERAL:
				expr = new StringLiteral (get_string (), src);
				break;
			case TokenType.IDENTIFIER:
				expr = new MemberAccess (null, get_string (), src);
				while (next () == TokenType.DOT) {
					if (next () != TokenType.IDENTIFIER) {
						Report.error (get_current_src (), "expected identifier got %s".printf (current.to_string ()));
						break;
					}
					expr = new MemberAccess (expr, get_string (), get_current_src ());
				}
				return expr;
			default:
				Report.error (src, "expected literal or symbol got %s".printf (current.to_string ()));
				break;
			}
			next ();
			return expr;
		}

		bool parse_args (Metadata metadata) {
			while (current != TokenType.EOF && has_space () && !has_newline ()) {
				SourceLocation begin = this.begin;
				var id = parse_identifier (false);
				if (id == null) {
					return false;
				}
				var arg_type = ArgumentType.from_string (id);
				if (arg_type == null) {
					Report.error (get_src (begin), "unknown argument");
					return false;
				}

				if (current != TokenType.ASSIGN) {
					// threat as `true'
					metadata.add_argument (arg_type, new Argument (new BooleanLiteral (true, get_src (begin)), get_src (begin)));
					continue;
				}
				next ();

				Expression expr = parse_expression ();
				if (expr == null) {
					return false;
				}
				metadata.add_argument (arg_type, new Argument (expr, get_src (begin)));
			}

			return true;
		}

		bool parse_rule () {
			var old_end = end;
			var metadata = parse_pattern ();
			if (metadata == null) {
				return false;
			}

			if (current == TokenType.EOF || old_end.line != end.line) {
				// eof or new rule
				return true;
			}
			return parse_args (metadata);
		}
	}

	/*
	 * GIR parser
	 */

	class Node {
		public static ArrayList<Node> new_namespaces = new ArrayList<Node> ();

		public weak Node parent;
		public string element_type;
		public string name;
		public Map<string,string> girdata = null;
		public Metadata metadata = Metadata.empty;
		public SourceReference source_reference = null;
		public ArrayList<Node> members = new ArrayList<Node> (); // guarantees fields order
		public HashMap<string, ArrayList<Node>> scope = new HashMap<string, ArrayList<Node>> (str_hash, str_equal);

		public Symbol symbol;
		public bool new_symbol;
		public bool merged;
		public bool processed;

		// function-specific
		public List<ParameterInfo> parameters;
		public ArrayList<int> array_length_parameters;
		public ArrayList<int> closure_parameters;
		public ArrayList<int> destroy_parameters;
		// alias-specific
		public DataType base_type;

		public Node (string? name) {
			this.name = name;
		}

		public void add_member (Node node) {
			var nodes = scope[node.name];
			if (nodes == null) {
				nodes = new ArrayList<Node> ();
				scope[node.name] = nodes;
			}
			nodes.add (node);
			members.add (node);
			node.parent = this;
		}

		public Node? lookup (string name, bool create_namespace = false, SourceReference? source_reference = null) {
			var nodes = scope[name];
			Node node = null;
			if (nodes != null) {
				node = nodes[0];
			}
			if (node == null) {
				Symbol sym = null;
				if (symbol != null) {
					sym = symbol.scope.lookup (name);
				}
				if (sym != null || create_namespace) {
					node = new Node (name);
					node.symbol = sym;
					node.new_symbol = node.symbol == null;
					node.source_reference = source_reference;
					add_member (node);

					if (sym == null) {
						new_namespaces.add (node);
					}
				}
			}
			return node;
		}

		public ArrayList<Node>? lookup_all (string name) {
			return scope[name];
		}

		public UnresolvedSymbol get_unresolved_symbol () {
			if (parent.name == null) {
				return new UnresolvedSymbol (null, name);
			} else {
				return new UnresolvedSymbol (parent.get_unresolved_symbol (), name);
			}
		}

		public string get_lower_case_cprefix () {
			if (name == null) {
				return "";
			}
			if (new_symbol) {
				return "%s%s_".printf (parent.get_lower_case_cprefix (), Symbol.camel_case_to_lower_case (name));
			} else {
				return symbol.get_lower_case_cprefix ();
			}
		}

		public string get_cprefix () {
			if (name == null) {
				return "";
			}
			if (new_symbol) {
				var cprefix = girdata["c:identifier-prefixes"];
				if (cprefix != null) {
					return cprefix;
				} else {
					return get_cname ();
				}
			} else {
				return symbol.get_cprefix ();
			}
		}

		public string get_cname () {
			if (name == null) {
				return "";
			}
			if (new_symbol) {
				var cname = girdata["c:identifier"];
				if (cname == null) {
					cname = girdata["c:type"];
				}
				if (cname == null) {
					if (symbol is Field) {
						if (((Field) symbol).binding == MemberBinding.STATIC) {
							cname = parent.get_lower_case_cprefix () + name;
						} else {
							cname = name;
						}
					} else {
						cname = "%s%s".printf (parent.get_cprefix (), name);
					}
				}
				return cname;
			} else {
				if (symbol is TypeSymbol) {
					return ((TypeSymbol) symbol).get_cname ();
				} else if (symbol is Constant) {
					return ((Constant) symbol).get_cname ();
				} else if (symbol is Method) {
					return ((Method) symbol).get_cname ();
				} else if (symbol is PropertyAccessor) {
					return ((PropertyAccessor) symbol).get_cname ();
				} else if (symbol is Field) {
					return ((Field) symbol).get_cname ();
				} else {
					assert_not_reached ();
				}
			}
		}

		public void process (GirParser parser) {
			if (processed) {
				return;
			}

			// process children allowing node removals
			for (int i=0; i < members.size; i++) {
				var node = members[i];
				node.process (parser);
				if (i < members.size && members[i] != node) {
					// node removed in the middle
					i--;
				}
			}

			if (girdata != null) {
				// GIR node processing
				if (symbol is Method) {
					var m = (Method) symbol;
					parser.process_callable (this);

					var colliding = parent.lookup_all (name);
					foreach (var node in colliding) {
						var sym = node.symbol;
						if (sym is Field && !(m.return_type is VoidType) && m.get_parameters().size == 0) {
							// assume method is getter
							merged = true;
						} else if (sym is Signal) {
							var sig = (Signal) sym;
							if (m.is_virtual) {
								sig.is_virtual = true;
							} else {
								sig.has_emitter = true;
							}
							parser.assume_parameter_names (sig, m, false);
							merged = true;
						} else if (sym is Method && !(sym is CreationMethod) && node != this) {
							if (m.is_virtual) {
								bool different_invoker = false;
								foreach (var attr in m.attributes) {
									if (attr.name == "NoWrapper") {
										/* no invoker but this method has the same name,
										   most probably the invoker has a different name
										   and g-ir-scanner missed it */
										var invoker = parser.find_invoker (this);
										if (invoker != null) {
											m.vfunc_name = m.name;
											m.name = invoker.symbol.name;
											m.attributes.remove (attr);
											invoker.processed = true;
											invoker.merged = true;
											different_invoker = true;
										}
									}
								}
								if (!different_invoker) {
									node.processed = true;
									node.merged = true;
								}
							}
						}
					}
					if (!(m is CreationMethod)) {
						// merge custom vfunc
						if (metadata.has_argument (ArgumentType.VFUNC_NAME)) {
							var vfunc = parent.lookup (metadata.get_string (ArgumentType.VFUNC_NAME));
							if (vfunc != null && vfunc != this) {
								vfunc.processed = true;
								vfunc.merged = true;
							}
						}
					}
					if (m.coroutine) {
						parser.process_async_method (this);
					}
				} else if (symbol is Property) {
					var colliding = parent.lookup_all (name);
					foreach (var node in colliding) {
						if (node.symbol is Signal) {
							// properties take precedence
							node.processed = true;
							node.merged = true;
						} else if (node.symbol is Method) {
							// getter in C, but not in Vala
							node.merged = true;
						}
					}
					var getter = parent.lookup ("get_%s".printf (name));
					var setter = parent.lookup ("set_%s".printf (name));
					var prop = (Property) symbol;
					if (prop.no_accessor_method) {
						// property getter and setter must both match, otherwise it's NoAccessorMethod
						prop.no_accessor_method = false;
						if (prop.get_accessor != null) {
							var m = getter != null ? getter.symbol as Method : null;
							if (m != null) {
								getter.process (parser);
								if (m.return_type is VoidType || m.get_parameters().size != 0) {
									prop.no_accessor_method = true;
								} else {
									if (getter.name == name) {
										foreach (var node in colliding) {
											if (node.symbol is Method) {
												node.merged = true;
											}
										}
									}
									prop.get_accessor.value_type.value_owned = m.return_type.value_owned;
								}
							} else {
								prop.no_accessor_method = true;
							}
						}
						if (!prop.no_accessor_method && prop.set_accessor != null && prop.set_accessor.writable) {
							var m = setter != null ? setter.symbol as Method : null;
							if (m != null) {
								setter.process (parser);
								if (!(m.return_type is VoidType) || m.get_parameters().size != 1) {
									prop.no_accessor_method = true;
								}
							} else {
								prop.no_accessor_method = true;
							}
						}
					}
				} else if (symbol is Field) {
					var field = (Field) symbol;
					var colliding = parent.lookup_all (name);
					if (colliding.size > 1) {
						// whatelse has precedence over the field
						merged = true;
					}

					var gtype_struct_for = parent.girdata["glib:is-gtype-struct-for"];
					if (field.variable_type is DelegateType && gtype_struct_for != null) {
						// virtual method field
						var d = ((DelegateType) field.variable_type).delegate_symbol;
						parser.process_virtual_method_field (this, d, parser.parse_symbol_from_string (gtype_struct_for, d.source_reference));
						merged = true;
					} else if (field.variable_type is ArrayType) {
						var array_length = parent.lookup ("n_%s".printf (field.name));
						if (array_length == null) {
							array_length = parent.lookup ("%s_length".printf (field.name));
						}
						if (array_length != null) {
							// array has length
							field.set_array_length_cname (array_length.symbol.name);
							field.no_array_length = false;
							field.array_null_terminated = false;
							array_length.processed = true;
							array_length.merged = true;
						}
					}
				} else if (symbol is Signal || symbol is Delegate) {
					parser.process_callable (this);
				} else if (symbol is Interface) {
					parser.process_interface (this);
				} else if (element_type == "alias") {
					parser.process_alias (this);
				} else if (symbol is Struct) {
					if (parent.symbol is ObjectTypeSymbol || parent.symbol is Struct) {
						// nested struct
						foreach (var fn in members) {
							var f = fn.symbol as Field;
							if (f != null) {
								if (f.binding == MemberBinding.INSTANCE) {
									f.set_cname (name + "." + f.get_cname ());
								}
								f.name = symbol.name + "_" + f.name;
								fn.name = f.name;
								parent.add_member (fn);
							}
						}
						merged = true;
					} else {
						// record for a gtype
						var gtype_struct_for = girdata["glib:is-gtype-struct-for"];
						if (gtype_struct_for != null) {
							var iface = parser.resolve_symbol (parent, parser.parse_symbol_from_string (gtype_struct_for, source_reference)) as Interface;
							if (iface != null) {
								// set the interface struct name
								iface.set_type_cname (((Struct) symbol).get_cname ());
							}
							merged = true;
						}
					}
				}

				// deprecation
				symbol.replacement = metadata.get_string (ArgumentType.REPLACEMENT);
				symbol.deprecated_since = metadata.get_string (ArgumentType.DEPRECATED_SINCE);
				if (symbol.deprecated_since == null) {
					symbol.deprecated_since = girdata.get ("deprecated-version");
				}
				symbol.deprecated = metadata.get_bool (ArgumentType.DEPRECATED) || symbol.replacement != null || symbol.deprecated_since != null;

				// cheader filename
				var cheader_filename = metadata.get_string (ArgumentType.CHEADER_FILENAME);
				if (cheader_filename != null) {
					foreach (string filename in cheader_filename.split (",")) {
						symbol.add_cheader_filename (filename);
					}
				}
			}

			var ns = symbol as Namespace;
			if (!(new_symbol && merged) && is_container (symbol)) {
				foreach (var node in members) {
					if (node.new_symbol && !node.merged && !metadata.get_bool (ArgumentType.HIDDEN) && !(ns != null && parent == parser.root && node.symbol is Method)) {
						add_symbol_to_container (symbol, node.symbol);
					}
				}

				var cl = symbol as Class;
				if (cl != null && !cl.is_compact && cl.default_construction_method == null) {
					// always provide constructor in generated bindings
					// to indicate that implicit Object () chainup is allowed
					var cm = new CreationMethod (null, null, cl.source_reference);
					cm.has_construct_function = false;
					cm.access = SymbolAccessibility.PROTECTED;
					cl.add_method (cm);
				} else if (symbol is Namespace && parent == parser.root) {
					// postprocess namespace methods
					foreach (var node in members) {
						var m = node.symbol as Method;
						if (m != null) {
							parser.process_namespace_method (ns, m);
						}
					}
				}
			}

			processed = true;
		}

		public string to_string () {
			if (parent.name == null) {
				return name;
			} else {
				return "%s.%s".printf (parent.to_string (), name);
			}
		}
	}

	static GLib.Regex type_from_string_regex;

	MarkupReader reader;

	CodeContext context;
	Namespace glib_ns;

	SourceFile current_source_file;
	Node root;

	SourceLocation begin;
	SourceLocation end;
	MarkupTokenType current_token;

	string[] cheader_filenames;

	ArrayList<Metadata> metadata_stack;
	Metadata metadata;
	ArrayList<Node> tree_stack;
	Node current;
	Node old_current;

	HashMap<UnresolvedSymbol,Symbol> unresolved_symbols_map = new HashMap<UnresolvedSymbol,Symbol> (unresolved_symbol_hash, unresolved_symbol_equal);
	ArrayList<UnresolvedSymbol> unresolved_gir_symbols = new ArrayList<UnresolvedSymbol> ();

	/**
	 * Parses all .gir source files in the specified code
	 * context and builds a code tree.
	 *
	 * @param context a code context
	 */
	public void parse (CodeContext context) {
		this.context = context;
		glib_ns = context.root.scope.lookup ("GLib") as Namespace;

		root = new Node (null);
		root.symbol = context.root;
		tree_stack = new ArrayList<Node> ();
		current = root;

		context.accept (this);

		resolve_gir_symbols ();
		create_new_namespaces ();

		root.process (this);

		foreach (var node in root.members) {
			report_unused_metadata (node.metadata);
		}
	}

	public override void visit_source_file (SourceFile source_file) {
		// collect gir namespaces
		foreach (var node in source_file.get_nodes ()) {
			if (node is Namespace) {
				var ns = (Namespace) node;
				var gir_namespace = source_file.gir_namespace;
				if (gir_namespace == null) {
					var a = ns.get_attribute ("CCode");
					if (a != null && a.has_argument ("gir_namespace")) {
						gir_namespace = a.get_string ("gir_namespace");
					}
				}
				if (gir_namespace != null && gir_namespace != ns.name) {
					var map_from = new UnresolvedSymbol (null, gir_namespace);
					set_symbol_mapping (map_from, ns);
					break;
				}
			}
		}

		if (source_file.filename.has_suffix (".gir")) {
			parse_file (source_file);
		}
	}

	public void parse_file (SourceFile source_file) {
		metadata_stack = new ArrayList<Metadata> ();
		metadata = Metadata.empty;

		// load metadata, first look into metadata directories then in the same directory of the .gir.
		string? metadata_filename = context.get_metadata_path (source_file.filename);
		if (metadata_filename != null && FileUtils.test (metadata_filename, FileTest.EXISTS)) {
			var metadata_parser = new MetadataParser ();
			var metadata_file = new SourceFile (context, source_file.file_type, metadata_filename);
			context.add_source_file (metadata_file);
			metadata = metadata_parser.parse_metadata (metadata_file);
		}

		this.current_source_file = source_file;
		reader = new MarkupReader (source_file.filename);

		// xml prolog
		next ();
		next ();

		next ();
		parse_repository ();

		reader = null;
		this.current_source_file = null;
	}

	void next () {
		current_token = reader.read_token (out begin, out end);

		// Skip *all* <doc> tags
		if (current_token == MarkupTokenType.START_ELEMENT && reader.name == "doc")
			skip_element();
	}

	void start_element (string name) {
		if (current_token != MarkupTokenType.START_ELEMENT || reader.name != name) {
			// error
			Report.error (get_current_src (), "expected start element of `%s'".printf (name));
		}
	}

	void end_element (string name) {
		if (current_token != MarkupTokenType.END_ELEMENT || reader.name != name) {
			// error
			Report.error (get_current_src (), "expected end element of `%s'".printf (name));
		}
		next ();
	}

	SourceReference get_current_src () {
		return new SourceReference (this.current_source_file, begin.line, begin.column, end.line, end.column);
	}

	const string GIR_VERSION = "1.2";

	static void add_symbol_to_container (Symbol container, Symbol sym) {
		if (container is Class) {
			unowned Class cl = (Class) container;

			if (sym is Class) {
				cl.add_class ((Class) sym);
			} else if (sym is Constant) {
				cl.add_constant ((Constant) sym);
			} else if (sym is Enum) {
				cl.add_enum ((Enum) sym);
			} else if (sym is Field) {
				cl.add_field ((Field) sym);
			} else if (sym is Method) {
				cl.add_method ((Method) sym);
			} else if (sym is Property) {
				cl.add_property ((Property) sym);
			} else if (sym is Signal) {
				cl.add_signal ((Signal) sym);
			} else if (sym is Struct) {
				cl.add_struct ((Struct) sym);
			}
		} else if (container is Enum) {
			unowned Enum en = (Enum) container;

			if (sym is EnumValue) {
				en.add_value ((EnumValue) sym);
			} else if (sym is Constant) {
				en.add_constant ((Constant) sym);
			} else if (sym is Method) {
				en.add_method ((Method) sym);
			}
		} else if (container is Interface) {
			unowned Interface iface = (Interface) container;

			if (sym is Class) {
				iface.add_class ((Class) sym);
			} else if (sym is Constant) {
				iface.add_constant ((Constant) sym);
			} else if (sym is Enum) {
				iface.add_enum ((Enum) sym);
			} else if (sym is Field) {
				iface.add_field ((Field) sym);
			} else if (sym is Method) {
				iface.add_method ((Method) sym);
			} else if (sym is Property) {
				iface.add_property ((Property) sym);
			} else if (sym is Signal) {
				iface.add_signal ((Signal) sym);
			} else if (sym is Struct) {
				iface.add_struct ((Struct) sym);
			}
		} else if (container is Namespace) {
			unowned Namespace ns = (Namespace) container;

			if (sym is Namespace) {
				ns.add_namespace ((Namespace) sym);
			} else if (sym is Class) {
				ns.add_class ((Class) sym);
			} else if (sym is Constant) {
				ns.add_constant ((Constant) sym);
			} else if (sym is Delegate) {
				ns.add_delegate ((Delegate) sym);
			} else if (sym is Enum) {
				ns.add_enum ((Enum) sym);
			} else if (sym is ErrorDomain) {
				ns.add_error_domain ((ErrorDomain) sym);
			} else if (sym is Field) {
				ns.add_field ((Field) sym);
			} else if (sym is Interface) {
				ns.add_interface ((Interface) sym);
			} else if (sym is Method) {
				ns.add_method ((Method) sym);
			} else if (sym is Namespace) {
				ns.add_namespace ((Namespace) sym);
			} else if (sym is Struct) {
				ns.add_struct ((Struct) sym);
			}
		} else if (container is Struct) {
			unowned Struct st = (Struct) container;

			if (sym is Constant) {
				st.add_constant ((Constant) sym);
			} else if (sym is Field) {
				st.add_field ((Field) sym);
			} else if (sym is Method) {
				st.add_method ((Method) sym);
			} else if (sym is Property) {
				st.add_property ((Property) sym);
			}
		} else if (container is ErrorDomain) {
			unowned ErrorDomain ed = (ErrorDomain) container;

			if (sym is ErrorCode) {
				ed.add_code ((ErrorCode) sym);
			} else if (sym is Method) {
				ed.add_method ((Method) sym);
			}
		} else {
			Report.error (sym.source_reference, "impossible to add `%s' to container `%s'".printf (sym.name, container.name));
		}
	}

	static bool is_container (Symbol sym) {
		return sym is ObjectTypeSymbol || sym is Struct || sym is Namespace || sym is ErrorDomain || sym is Enum;
	}

	UnresolvedSymbol? parse_symbol_from_string (string symbol_string, SourceReference? source_reference = null) {
		UnresolvedSymbol? sym = null;
		foreach (unowned string s in symbol_string.split (".")) {
			sym = new UnresolvedSymbol (sym, s, source_reference);
		}
		if (sym == null) {
			Report.error (source_reference, "a symbol must be specified");
		}
		return sym;
	}

	void set_symbol_mapping (UnresolvedSymbol map_from, Symbol map_to) {
		// last mapping is the most up-to-date
		if (map_from is UnresolvedSymbol) {
			unresolved_symbols_map[(UnresolvedSymbol) map_from] = map_to;
		}
	}

	void assume_parameter_names (Signal sig, Symbol sym, bool skip_first) {
		Iterator<Parameter> iter;
		if (sym is Method) {
			iter = ((Method) sym).get_parameters ().iterator ();
		} else {
			iter = ((Delegate) sym).get_parameters ().iterator ();
		}
		bool first = true;
		foreach (var param in sig.get_parameters ()) {
			if (!iter.next ()) {
				// unreachable for valid GIR
				break;
			}
			if (skip_first && first) {
				if (!iter.next ()) {
					// unreachable for valid GIR
					break;
				}
				first = false;
			}
			param.name = iter.get ().name;
		}
	}

	Node? find_invoker (Node node) {
		/* most common use case is invoker has at least the given method prefix
		   and the same parameter names */
		var m = (Method) node.symbol;
		var prefix = "%s_".printf (m.name);
		foreach (var n in node.parent.members) {
			if (!n.symbol.name.has_prefix (prefix)) {
				continue;
			}
			Method? invoker = n.symbol as Method;
			if (invoker == null || (m.get_parameters().size != invoker.get_parameters().size)) {
				continue;
			}
			var iter = invoker.get_parameters ().iterator ();
			foreach (var param in m.get_parameters ()) {
				assert (iter.next ());
				if (param.name != iter.get().name)	{
					invoker = null;
					break;
				}
			}
			if (invoker != null) {
				return n;
			}
		}

		return null;
	}

	Metadata get_current_metadata () {
		var selector = reader.name;
		var child_name = reader.get_attribute ("name");
		if (child_name == null) {
			return Metadata.empty;
		}
		selector = selector.replace ("-", "_");
		child_name = child_name.replace ("-", "_");

		if (selector.has_prefix ("glib:")) {
			selector = selector.substring ("glib:".length);
		}

		return metadata.match_child (child_name, selector);
	}

	bool push_metadata () {
		var new_metadata = get_current_metadata ();
		// skip ?
		if (new_metadata.has_argument (ArgumentType.SKIP)) {
			if (new_metadata.get_bool (ArgumentType.SKIP)) {
				return false;
			}
		} else if (reader.get_attribute ("introspectable") == "0") {
			return false;
		}

		metadata_stack.add (metadata);
		metadata = new_metadata;

		return true;
	}

	void pop_metadata () {
		metadata = metadata_stack[metadata_stack.size - 1];
		metadata_stack.remove_at (metadata_stack.size - 1);
	}

	bool parse_type_arguments_from_string (DataType parent_type, string type_arguments, SourceReference? source_reference = null) {
		int type_arguments_length = (int) type_arguments.length;
		GLib.StringBuilder current = new GLib.StringBuilder.sized (type_arguments_length);

		int depth = 0;
		for (var c = 0 ; c < type_arguments_length ; c++) {
			if (type_arguments[c] == '<' || type_arguments[c] == '[') {
				depth++;
				current.append_unichar (type_arguments[c]);
			} else if (type_arguments[c] == '>' || type_arguments[c] == ']') {
				depth--;
				current.append_unichar (type_arguments[c]);
			} else if (type_arguments[c] == ',') {
				if (depth == 0) {
					var dt = parse_type_from_string (current.str, true, source_reference);
					if (dt == null) {
						return false;
					}
					parent_type.add_type_argument (dt);
					current.truncate ();
				} else {
					current.append_unichar (type_arguments[c]);
				}
			} else {
				current.append_unichar (type_arguments[c]);
			}
		}

		var dt = parse_type_from_string (current.str, true, source_reference);
		if (dt == null) {
			return false;
		}
		parent_type.add_type_argument (dt);

		return true;
	}

	DataType? parse_type_from_string (string type_string, bool owned_by_default, SourceReference? source_reference = null) {
		if (type_from_string_regex == null) {
			try {
				type_from_string_regex = new GLib.Regex ("^(?:(owned|unowned|weak) +)?([0-9a-zA-Z_\\.]+)(?:<(.+)>)?(\\*+)?(\\[,*\\])?(\\?)?$", GLib.RegexCompileFlags.ANCHORED | GLib.RegexCompileFlags.DOLLAR_ENDONLY | GLib.RegexCompileFlags.OPTIMIZE);
			} catch (GLib.RegexError e) {
				GLib.error ("Unable to compile regex: %s", e.message);
			}
		}

		GLib.MatchInfo match;
		if (!type_from_string_regex.match (type_string, 0, out match)) {
			Report.error (source_reference, "unable to parse type");
			return null;
		}

		DataType? type = null;

		var ownership_data = match.fetch (1);
		var type_name = match.fetch (2);
		var type_arguments_data = match.fetch (3);
		var pointers_data = match.fetch (4);
		var array_data = match.fetch (5);
		var nullable_data = match.fetch (6);

		var nullable = nullable_data != null && nullable_data.length > 0;

		if (ownership_data == null && type_name == "void") {
			if (array_data == null && !nullable) {
				type = new VoidType (source_reference);
				if (pointers_data != null) {
					for (int i=0; i < pointers_data.length; i++) {
						type = new PointerType (type);
					}
				}
				return type;
			} else {
				Report.error (source_reference, "invalid void type");
				return null;
			}
		}

		bool value_owned = owned_by_default;

		if (ownership_data == "owned") {
			if (owned_by_default) {
				Report.error (source_reference, "unexpected `owned' keyword");
			} else {
				value_owned = true;
			}
		} else if (ownership_data == "unowned") {
			if (owned_by_default) {
				value_owned = false;
			} else {
				Report.error (source_reference, "unexpected `unowned' keyword");
				return null;
			}
		}

		var sym = parse_symbol_from_string (type_name, source_reference);
		if (sym == null) {
			return null;
		}
		type = new UnresolvedType.from_symbol (sym, source_reference);

		if (type_arguments_data != null && type_arguments_data.length > 0) {
			if (!parse_type_arguments_from_string (type, type_arguments_data, source_reference)) {
				return null;
			}
		}

		if (pointers_data != null) {
			for (int i=0; i < pointers_data.length; i++) {
				type = new PointerType (type);
			}
		}

		if (array_data != null) {
			type = new ArrayType (type, (int) array_data.length - 1, source_reference);
		}

		type.nullable = nullable;
		type.value_owned = value_owned;
		return type;
	}

	string? element_get_string (string attribute_name, ArgumentType arg_type) {
		if (metadata.has_argument (arg_type)) {
			return metadata.get_string (arg_type);
		} else {
			return reader.get_attribute (attribute_name);
		}
	}

	/*
	 * The changed is a faster way to check whether the type has changed and it may affect the C declaration.
	 */
	DataType? element_get_type (DataType orig_type, bool owned_by_default, ref bool no_array_length, out bool changed = null) {
		changed = false;
		var type = orig_type;

		if (metadata.has_argument (ArgumentType.TYPE)) {
			type = parse_type_from_string (metadata.get_string (ArgumentType.TYPE), owned_by_default, metadata.get_source_reference (ArgumentType.TYPE));
			changed = true;
		} else if (!(type is VoidType)) {
			if (metadata.has_argument (ArgumentType.TYPE_ARGUMENTS)) {
				type.remove_all_type_arguments ();
				parse_type_arguments_from_string (type, metadata.get_string (ArgumentType.TYPE_ARGUMENTS), metadata.get_source_reference (ArgumentType.TYPE_ARGUMENTS));
			}

			if (metadata.get_bool (ArgumentType.ARRAY)) {
				type = new ArrayType (type, 1, type.source_reference);
				changed = true;
			}

			if (type.value_owned) {
				if (metadata.has_argument (ArgumentType.UNOWNED)) {
					type.value_owned = !metadata.get_bool (ArgumentType.UNOWNED);
				}
			} else {
				if (metadata.has_argument (ArgumentType.OWNED)) {
					type.value_owned = metadata.get_bool (ArgumentType.OWNED);
				}
			}
			if (metadata.has_argument (ArgumentType.NULLABLE)) {
				type.nullable = metadata.get_bool (ArgumentType.NULLABLE);
			}
		}

		if (type is ArrayType && !(orig_type is ArrayType)) {
			no_array_length = true;
		}

		return type;
	}

	string? element_get_name (string? gir_name = null) {
		var name = gir_name;
		if (name == null) {
			name = reader.get_attribute ("name");
		}
		var pattern = metadata.get_string (ArgumentType.NAME);
		if (pattern != null) {
			try {
				var regex = new Regex (pattern, RegexCompileFlags.ANCHORED, RegexMatchFlags.ANCHORED);
				GLib.MatchInfo match;
				if (!regex.match (name, 0, out match)) {
					name = pattern;
				} else {
					var matched = match.fetch (1);
					if (matched != null && matched.length > 0) {
						name = matched;
					} else {
						name = pattern;
					}
				}
			} catch (Error e) {
				name = pattern;
			}
		} else {
			if (name != null && name.has_suffix ("Enum")) {
				name = name.substring (0, name.length - "Enum".length);
			}
		}

		return name;
	}

	void set_array_ccode (Symbol sym, ParameterInfo info) {
		if (sym is Method) {
			var m = (Method) sym;
			m.carray_length_parameter_position = info.vala_idx;
		} else if (sym is Delegate) {
			var d = (Delegate) sym;
			d.carray_length_parameter_position = info.vala_idx;
		} else {
			var param = (Parameter) sym;
			param.carray_length_parameter_position = info.vala_idx;
			param.set_array_length_cname (info.param.name);
		}
		var type_name = info.param.variable_type.to_qualified_string ();
		if (type_name != "int") {
			var st = context.root.scope.lookup (type_name) as Struct;
			if (st != null) {
				if (sym is Method) {
					var m = (Method) sym;
					m.array_length_type = st.get_cname ();
				} else {
					var param = (Parameter) sym;
					param.array_length_type = st.get_cname ();
				}
			}
		}
	}

	void parse_repository () {
		start_element ("repository");
		if (reader.get_attribute ("version") != GIR_VERSION) {
			Report.error (get_current_src (), "unsupported GIR version %s (supported: %s)".printf (reader.get_attribute ("version"), GIR_VERSION));
			return;
		}
		next ();
		while (current_token == MarkupTokenType.START_ELEMENT) {
			if (reader.name == "namespace") {
				parse_namespace ();
			} else if (reader.name == "include") {
				parse_include ();
			} else if (reader.name == "package") {
				var pkg = parse_package ();
				if (context.has_package (pkg)) {
					// package already provided elsewhere, stop parsing this GIR
					return;
				} else {
					context.add_package (pkg);
				}
			} else if (reader.name == "c:include") {
				parse_c_include ();
			} else {
				// error
				Report.error (get_current_src (), "unknown child element `%s' in `repository'".printf (reader.name));
				skip_element ();
			}
		}
		end_element ("repository");
	}

	void parse_include () {
		start_element ("include");
		var pkg = reader.get_attribute ("name");
		var version = reader.get_attribute ("version");
		if (version != null) {
			pkg = "%s-%s".printf (pkg, version);
		}
		// add the package to the queue
		context.add_external_package (pkg);
		next ();
		end_element ("include");
	}

	string parse_package () {
		start_element ("package");
		var pkg = reader.get_attribute ("name");
		next ();
		end_element ("package");
		return pkg;
	}

	void parse_c_include () {
		start_element ("c:include");
		cheader_filenames += reader.get_attribute ("name");
		next ();
		end_element ("c:include");
	}

	void skip_element () {
		next ();

		int level = 1;
		while (level > 0) {
			if (current_token == MarkupTokenType.START_ELEMENT) {
				level++;
			} else if (current_token == MarkupTokenType.END_ELEMENT) {
				level--;
			} else if (current_token == MarkupTokenType.EOF) {
				Report.error (get_current_src (), "unexpected end of file");
				break;
			}
			next ();
		}
	}

	Node? resolve_node (Node parent_scope, UnresolvedSymbol unresolved_sym, bool create_namespace = false) {
		if (unresolved_sym.inner == null) {
			var scope = parent_scope;
			while (scope != null) {
				var node = scope.lookup (unresolved_sym.name, create_namespace, unresolved_sym.source_reference);
				if (node != null) {
					return node;
				}
				scope = scope.parent;
			}
		} else {
			var inner = resolve_node (parent_scope, unresolved_sym.inner, create_namespace);
			if (inner != null) {
				return inner.lookup (unresolved_sym.name, create_namespace, unresolved_sym.source_reference);
			}
		}
		return null;
	}

	Symbol? resolve_symbol (Node parent_scope, UnresolvedSymbol unresolved_sym) {
		var node = resolve_node (parent_scope, unresolved_sym);
		if (node != null) {
			return node.symbol;
		}
		return null;
	}

	void push_node (string name, bool merge) {
		var parent = current;
		if (metadata.has_argument (ArgumentType.PARENT)) {
			var target = parse_symbol_from_string (metadata.get_string (ArgumentType.PARENT), metadata.get_source_reference (ArgumentType.PARENT));
			parent = resolve_node (root, target, true);
		}

		var node = parent.lookup (name);
		if (node == null || (node.symbol != null && !merge)) {
			node = new Node (name);
			node.new_symbol = true;
		}
		node.element_type = reader.name;
		node.girdata = reader.get_attributes ();
		node.metadata = metadata;
		node.source_reference = get_current_src ();
		parent.add_member (node);

		var gir_name = node.girdata["name"];
		if (gir_name == null) {
			gir_name = node.girdata["glib:name"];
		}
		if (parent != current || gir_name != name) {
			set_symbol_mapping (new UnresolvedSymbol (null, gir_name), node.get_unresolved_symbol ());
		}

		tree_stack.add (current);
		current = node;
	}

	void pop_node () {
		old_current = current;
		current = tree_stack[tree_stack.size - 1];
		tree_stack.remove_at (tree_stack.size - 1);
	}

	void parse_namespace () {
		start_element ("namespace");

		string? cprefix = reader.get_attribute ("c:identifier-prefixes");
		string vala_namespace = cprefix;
		string gir_namespace = reader.get_attribute ("name");
		string gir_version = reader.get_attribute ("version");

		var ns_metadata = metadata.match_child (gir_namespace);
		if (ns_metadata.has_argument (ArgumentType.NAME)) {
			vala_namespace = ns_metadata.get_string (ArgumentType.NAME);
		}
		if (vala_namespace == null) {
			vala_namespace = gir_namespace;
		}

		current_source_file.gir_namespace = gir_namespace;
		current_source_file.gir_version = gir_version;

		Namespace ns;
		push_node (vala_namespace, true);
		if (current.new_symbol) {
			ns = new Namespace (vala_namespace, current.source_reference);
			current.symbol = ns;
		} else {
			ns = (Namespace) current.symbol;
			ns.attributes = null;
			ns.source_reference = current.source_reference;
		}

		if (cprefix != null) {
			ns.add_cprefix (cprefix);
			ns.set_lower_case_cprefix (Symbol.camel_case_to_lower_case (cprefix) + "_");
		}

		if (ns_metadata.has_argument (ArgumentType.CHEADER_FILENAME)) {
			var val = ns_metadata.get_string (ArgumentType.CHEADER_FILENAME);
			foreach (string filename in val.split (",")) {
				ns.add_cheader_filename (filename);
			}
		} else {
			foreach (string c_header in cheader_filenames) {
				ns.add_cheader_filename (c_header);
			}
		}

		next ();
		while (current_token == MarkupTokenType.START_ELEMENT) {
			if (!push_metadata ()) {
				skip_element ();
				continue;
			}

			if (reader.name == "alias") {
				parse_alias ();
			} else if (reader.name == "enumeration") {
				if (reader.get_attribute ("glib:error-quark") != null) {
					parse_error_domain ();
				} else {
					parse_enumeration ();
				}
			} else if (reader.name == "bitfield") {
				parse_bitfield ();
			} else if (reader.name == "function") {
				parse_method ("function");
			} else if (reader.name == "callback") {
				parse_callback ();
			} else if (reader.name == "record") {
				if (reader.get_attribute ("glib:get-type") != null && !metadata.get_bool (ArgumentType.STRUCT)) {
					parse_boxed ("record");
				} else {
					if (!reader.get_attribute ("name").has_suffix ("Private")) {
						parse_record ();
					} else {
						skip_element ();
					}
				}
			} else if (reader.name == "class") {
				parse_class ();
			} else if (reader.name == "interface") {
				parse_interface ();
			} else if (reader.name == "glib:boxed") {
				parse_boxed ("glib:boxed");
			} else if (reader.name == "union") {
				parse_union ();
			} else if (reader.name == "constant") {
				parse_constant ();
			} else {
				// error
				Report.error (get_current_src (), "unknown child element `%s' in `namespace'".printf (reader.name));
				skip_element ();
			}

			pop_metadata ();
		}
		pop_node ();
		end_element ("namespace");
	}

	void parse_alias () {
		start_element ("alias");
		push_node (element_get_name (), true);
		// not enough information, symbol will be created while processing the tree

		next ();
		bool no_array_length = false;
		current.base_type = element_get_type (parse_type (null, null, true), true, ref no_array_length);

		pop_node ();
		end_element ("alias");
	}

	private void calculate_common_prefix (ref string common_prefix, string cname) {
		if (common_prefix == null) {
			common_prefix = cname;
			while (common_prefix.length > 0 && !common_prefix.has_suffix ("_")) {
				// FIXME: could easily be made faster
				common_prefix = common_prefix.substring (0, common_prefix.length - 1);
			}
		} else {
			while (!cname.has_prefix (common_prefix)) {
				common_prefix = common_prefix.substring (0, common_prefix.length - 1);
			}
		}
		while (common_prefix.length > 0 && (!common_prefix.has_suffix ("_") ||
		       (cname.get_char (common_prefix.length).isdigit ()) && (cname.length - common_prefix.length) <= 1)) {
			// enum values may not consist solely of digits
			common_prefix = common_prefix.substring (0, common_prefix.length - 1);
		}
	}

	void parse_enumeration (string element_name = "enumeration", bool error_domain = false) {
		start_element (element_name);
		push_node (element_get_name (), true);

		Symbol sym;
		if (current.new_symbol) {
			if (error_domain) {
				sym = new ErrorDomain (current.name, current.source_reference);
			} else {
				var en = new Enum (current.name, current.source_reference);
				if (element_name == "bitfield") {
					en.is_flags = true;
				}
				sym = en;
			}
			current.symbol = sym;
		} else {
			sym = current.symbol;
		}
		sym.external = true;
		sym.access = SymbolAccessibility.PUBLIC;

		string cname = reader.get_attribute ("c:type");
		string common_prefix = null;

		next ();
		
		while (current_token == MarkupTokenType.START_ELEMENT) {
			if (!push_metadata ()) {
				skip_element ();
				continue;
			}

			if (reader.name == "member") {
				if (error_domain) {
					parse_error_member ();
					calculate_common_prefix (ref common_prefix, old_current.get_cname ());
				} else {
					parse_enumeration_member ();
					calculate_common_prefix (ref common_prefix, old_current.get_cname ());
				}
			} else {
				// error
				Report.error (get_current_src (), "unknown child element `%s' in `%s'".printf (reader.name, element_name));
				skip_element ();
			}

			pop_metadata ();
		}

		if (cname != null) {
			if (sym is Enum) {
				((Enum) sym).set_cname (cname);
				((Enum) sym).set_cprefix (common_prefix);
			} else {
				((ErrorDomain) sym).set_cname (cname);
				((ErrorDomain) sym).set_cprefix (common_prefix);
			}
		}

		pop_node ();
		end_element (element_name);
	}

	void parse_error_domain () {
		parse_enumeration ("enumeration", true);
	}

	void parse_bitfield () {
		parse_enumeration ("bitfield");
	}

	void parse_enumeration_member () {
		start_element ("member");
		push_node (element_get_name().up().replace ("-", "_"), false);

		var ev = new EnumValue (current.name, metadata.get_expression (ArgumentType.DEFAULT), current.source_reference);
		var cname = reader.get_attribute ("c:identifier");
		if (cname != null) {
			ev.set_cname (cname);
		}
		current.symbol = ev;
		next ();

		pop_node ();
		end_element ("member");
	}

	void parse_error_member () {
		start_element ("member");
		push_node (element_get_name().up().replace ("-", "_"), false);

		ErrorCode ec;
		string value = reader.get_attribute ("value");
		if (value != null) {
			ec = new ErrorCode.with_value (current.name, new IntegerLiteral (value));
		} else {
			ec = new ErrorCode (current.name);
		}
		current.symbol = ec;
		var cname = reader.get_attribute ("c:identifier");
		if (cname != null) {
			ec.set_cname (cname);
		}
		next ();

		pop_node ();
		end_element ("member");
	}

	DataType parse_return_value (out string? ctype = null) {
		start_element ("return-value");

		string transfer = reader.get_attribute ("transfer-ownership");
		string allow_none = reader.get_attribute ("allow-none");
		next ();
		var transfer_elements = transfer != "container";
		var type = parse_type (out ctype, null, transfer_elements);
		if (transfer == "full" || transfer == "container") {
			type.value_owned = true;
		}
		if (allow_none == "1") {
			type.nullable = true;
		}
		end_element ("return-value");
		return type;
	}

	Parameter parse_parameter (out int array_length_idx = null, out int closure_idx = null, out int destroy_idx = null, out string? scope = null, string? default_name = null) {
		Parameter param;

		array_length_idx = -1;
		closure_idx = -1;
		destroy_idx = -1;

		start_element ("parameter");
		string name = reader.get_attribute ("name");
		if (name == null) {
			name = default_name;
		}
		string direction = null;
		if (metadata.has_argument (ArgumentType.OUT)) {
			if (metadata.get_bool (ArgumentType.OUT)) {
				direction = "out";
			} // null otherwise
		} else if (metadata.has_argument (ArgumentType.REF)) {
			if (metadata.get_bool (ArgumentType.REF)) {
				direction = "inout";
			} // null otherwise
		} else {
			direction = reader.get_attribute ("direction");
		}
		string transfer = reader.get_attribute ("transfer-ownership");
		string allow_none = reader.get_attribute ("allow-none");

		scope = element_get_string ("scope", ArgumentType.SCOPE);

		string closure = reader.get_attribute ("closure");
		string destroy = reader.get_attribute ("destroy");
		if (closure != null && &closure_idx != null) {
			closure_idx = int.parse (closure);
		}
		if (destroy != null && &destroy_idx != null) {
			destroy_idx = int.parse (destroy);
		}

		next ();
		if (reader.name == "varargs") {
			start_element ("varargs");
			next ();
			param = new Parameter.with_ellipsis (get_current_src ());
			end_element ("varargs");
		} else {
			string ctype;
			bool no_array_length;
			bool array_null_terminated;
			var type = parse_type (out ctype, out array_length_idx, transfer != "container", out no_array_length, out array_null_terminated);
			if (transfer == "full" || transfer == "container" || destroy != null) {
				type.value_owned = true;
			}
			if (allow_none == "1" && direction != "out") {
				type.nullable = true;
			}

			bool changed;
			type = element_get_type (type, direction == "out" || direction == "ref", ref no_array_length, out changed);
			if (!changed) {
				// discard ctype, duplicated information
				ctype = null;
			}

			if (type is ArrayType && metadata.has_argument (ArgumentType.ARRAY_LENGTH_IDX)) {
				array_length_idx = metadata.get_integer (ArgumentType.ARRAY_LENGTH_IDX);
			}

			param = new Parameter (name, type, get_current_src ());
			param.ctype = ctype;
			if (direction == "out") {
				param.direction = ParameterDirection.OUT;
			} else if (direction == "inout") {
				param.direction = ParameterDirection.REF;
			}
			if (type is ArrayType && metadata.has_argument (ArgumentType.ARRAY_LENGTH_IDX)) {
				array_length_idx = metadata.get_integer (ArgumentType.ARRAY_LENGTH_IDX);
			} else {
				param.no_array_length = no_array_length;
				param.array_null_terminated = array_null_terminated;
			}
			param.initializer = metadata.get_expression (ArgumentType.DEFAULT);
		}
		end_element ("parameter");
		return param;
	}

	DataType parse_type (out string? ctype = null, out int array_length_idx = null, bool transfer_elements = true, out bool no_array_length = null, out bool array_null_terminated = null) {
		bool is_array = false;
		string type_name = reader.get_attribute ("name");

		array_length_idx = -1;
		no_array_length = true;
		array_null_terminated = true;

		if (reader.name == "array") {
			is_array = true;
			start_element ("array");

			if (type_name == null) {
				if (reader.get_attribute ("length") != null) {
					array_length_idx = int.parse (reader.get_attribute ("length"));
					no_array_length = false;
					array_null_terminated = false;
				}
				if (reader.get_attribute ("fixed-size") != null) {
					array_null_terminated = false;
				}
				next ();
				var element_type = parse_type ();
				end_element ("array");
				return new ArrayType (element_type, 1, null);
			}
		} else if (reader.name == "callback"){
			parse_callback ();
			return new DelegateType ((Delegate) old_current.symbol);
		} else {
			start_element ("type");
		}

		ctype = reader.get_attribute("c:type");

		next ();

		if (type_name == "GLib.PtrArray"
		    && current_token == MarkupTokenType.START_ELEMENT) {
			type_name = "GLib.GenericArray";
		}

		DataType type = parse_type_from_gir_name (type_name, out no_array_length, out array_null_terminated, ctype);

		// type arguments / element types
		while (current_token == MarkupTokenType.START_ELEMENT) {
			if (type_name == "GLib.ByteArray") {
				skip_element ();
				continue;
			}
			var element_type = parse_type ();
			element_type.value_owned = transfer_elements;
			type.add_type_argument (element_type);
		}

		end_element (is_array ? "array" : "type");
		return type;
	}

	DataType parse_type_from_gir_name (string type_name, out bool no_array_length = null, out bool array_null_terminated = null, string? ctype = null) {
		no_array_length = false;
		array_null_terminated = false;

		DataType type;
		if (type_name == "none") {
			type = new VoidType (get_current_src ());
		} else if (type_name == "gpointer") {
			type = new PointerType (new VoidType (get_current_src ()), get_current_src ());
		} else if (type_name == "GObject.Strv") {
			type = new ArrayType (new UnresolvedType.from_symbol (new UnresolvedSymbol (null, "string")), 1, get_current_src ());
			no_array_length = true;
			array_null_terminated = true;
		} else {
			bool known_type = true;
			if (type_name == "utf8") {
				type_name = "string";
			} else if (type_name == "gboolean") {
				type_name = "bool";
			} else if (type_name == "gchar") {
				type_name = "char";
			} else if (type_name == "gshort") {
				type_name = "short";
			} else if (type_name == "gushort") {
				type_name = "ushort";
			} else if (type_name == "gint") {
				type_name = "int";
			} else if (type_name == "guint") {
				type_name = "uint";
			} else if (type_name == "glong") {
				if (ctype != null && ctype.has_prefix ("gssize")) {
					type_name = "ssize_t";
				} else {
					type_name = "long";
				}
			} else if (type_name == "gulong") {
				if (ctype != null && ctype.has_prefix ("gsize")) {
					type_name = "size_t";
				} else {
					type_name = "ulong";
				}
			} else if (type_name == "gint8") {
				type_name = "int8";
			} else if (type_name == "guint8") {
				type_name = "uint8";
			} else if (type_name == "gint16") {
				type_name = "int16";
			} else if (type_name == "guint16") {
				type_name = "uint16";
			} else if (type_name == "gint32") {
				type_name = "int32";
			} else if (type_name == "guint32") {
				type_name = "uint32";
			} else if (type_name == "gint64") {
				type_name = "int64";
			} else if (type_name == "guint64") {
				type_name = "uint64";
			} else if (type_name == "gfloat") {
				type_name = "float";
			} else if (type_name == "gdouble") {
				type_name = "double";
			} else if (type_name == "filename") {
				type_name = "string";
			} else if (type_name == "GLib.offset") {
				type_name = "int64";
			} else if (type_name == "gsize") {
				type_name = "size_t";
			} else if (type_name == "gssize") {
				type_name = "ssize_t";
			} else if (type_name == "GType") {
				type_name = "GLib.Type";
			} else if (type_name == "GLib.String") {
				type_name = "GLib.StringBuilder";
			} else if (type_name == "GObject.Class") {
				type_name = "GLib.ObjectClass";
			} else if (type_name == "gunichar") {
				type_name = "unichar";
			} else if (type_name == "GLib.Data") {
				type_name = "GLib.Datalist";
			} else if (type_name == "Atk.ImplementorIface") {
				type_name = "Atk.Implementor";
			} else {
				known_type = false;
			}
			var sym = parse_symbol_from_string (type_name, get_current_src ());
			type = new UnresolvedType.from_symbol (sym, get_current_src ());
			if (!known_type) {
				unresolved_gir_symbols.add (sym);
			}
		}

		return type;
	}

	void parse_record () {
		start_element ("record");
		push_node (element_get_name (), true);

		Struct st;
		if (current.new_symbol) {
			st = new Struct (reader.get_attribute ("name"), current.source_reference);
			var cname = reader.get_attribute ("c:type");
			if (cname != null) {
				st.set_cname (cname);
			}
			current.symbol = st;
		} else {
			st = (Struct) current.symbol;
		}
		st.external = true;
		st.access = SymbolAccessibility.PUBLIC;

		var gtype_struct_for = reader.get_attribute ("glib:is-gtype-struct-for");
		bool first_field = true;
		next ();
		while (current_token == MarkupTokenType.START_ELEMENT) {
			if (!push_metadata ()) {
				skip_element ();
				continue;
			}

			if (reader.name == "field") {
				if (reader.get_attribute ("name") != "priv" && !(first_field && gtype_struct_for != null)) {
					parse_field ();
				} else {
					skip_element ();
				}
				first_field = false;
			} else if (reader.name == "constructor") {
				parse_constructor ();
			} else if (reader.name == "method") {
				parse_method ("method");
			} else if (reader.name == "union") {
				parse_union ();
			} else {
				// error
				Report.error (get_current_src (), "unknown child element `%s' in `record'".printf (reader.name));
				skip_element ();
			}

			pop_metadata ();
		}

		pop_node ();
		end_element ("record");
	}

	void parse_class () {
		start_element ("class");
		push_node (element_get_name (), true);

		Class cl;
		var parent = reader.get_attribute ("parent");
		if (current.new_symbol) {
			cl = new Class (current.name, current.source_reference);
			cl.set_type_id ("%s ()".printf (reader.get_attribute ("glib:get-type")));
			var cname = reader.get_attribute ("c:type");
			if (cname != null) {
				cl.set_cname (cname);
			}

			if (parent != null) {
				cl.add_base_type (parse_type_from_gir_name (parent));
			}
			current.symbol = cl;
		} else {
			cl = (Class) current.symbol;
		}
		cl.access = SymbolAccessibility.PUBLIC;
		cl.external = true;

		next ();
		var first_field = true;
		while (current_token == MarkupTokenType.START_ELEMENT) {
			if (!push_metadata ()) {
				skip_element ();
				continue;
			}

			if (reader.name == "implements") {
				start_element ("implements");
				cl.add_base_type (parse_type_from_gir_name (reader.get_attribute ("name")));
				next ();
				end_element ("implements");
			} else if (reader.name == "constant") {
				parse_constant ();
			} else if (reader.name == "field") {
				if (first_field && parent != null) {
					// first field is guaranteed to be the parent instance
					skip_element ();
				} else {
					if (reader.get_attribute ("name") != "priv") {
						parse_field ();
					} else {
						skip_element ();
					}
				}
				first_field = false;
			} else if (reader.name == "property") {
				parse_property ();
			} else if (reader.name == "constructor") {
				parse_constructor ();
			} else if (reader.name == "function") {
				parse_method ("function");
			} else if (reader.name == "method") {
				parse_method ("method");
			} else if (reader.name == "virtual-method") {
				parse_method ("virtual-method");
			} else if (reader.name == "union") {
				parse_union ();
			} else if (reader.name == "glib:signal") {
				parse_signal ();
			} else {
				// error
				Report.error (get_current_src (), "unknown child element `%s' in `class'".printf (reader.name));
				skip_element ();
			}

			pop_metadata ();
		}

		pop_node ();
		end_element ("class");
	}

	void parse_interface () {
		start_element ("interface");
		push_node (element_get_name (), true);

		Interface iface;
		if (current.new_symbol) {
			iface = new Interface (current.name, current.source_reference);
			var cname = reader.get_attribute ("c:type");
			if (cname != null) {
				iface.set_cname (cname);
			}
			var typeid = reader.get_attribute ("glib:get-type");
			if (typeid != null) {
				iface.set_type_id ("%s ()".printf (typeid));
			}

			current.symbol = iface;
		} else {
			iface = (Interface) current.symbol;
		}

		iface.access = SymbolAccessibility.PUBLIC;
		iface.external = true;


		next ();
		while (current_token == MarkupTokenType.START_ELEMENT) {
			if (!push_metadata ()) {
				skip_element ();
				continue;
			}

			if (reader.name == "prerequisite") {
				start_element ("prerequisite");
				iface.add_prerequisite (parse_type_from_gir_name (reader.get_attribute ("name")));
				next ();
				end_element ("prerequisite");
			} else if (reader.name == "field") {
				parse_field ();
			} else if (reader.name == "property") {
				parse_property ();
			} else if (reader.name == "virtual-method") {
				parse_method ("virtual-method");
			} else if (reader.name == "function") {
				parse_method ("function");
			} else if (reader.name == "method") {
				parse_method ("method");
			} else if (reader.name == "glib:signal") {
				parse_signal ();
			} else {
				// error
				Report.error (get_current_src (), "unknown child element `%s' in `interface'".printf (reader.name));
				skip_element ();
			}

			pop_metadata ();
		}

		pop_node ();
		end_element ("interface");
	}

	void parse_field () {
		start_element ("field");
		push_node (element_get_name (), false);

		string allow_none = reader.get_attribute ("allow-none");
		next ();
		var type = parse_type ();
		bool no_array_length = true;
		type = element_get_type (type, true, ref no_array_length);

		var field = new Field (current.name, type, null, current.source_reference);
		field.access = SymbolAccessibility.PUBLIC;
		field.no_array_length = no_array_length;
		field.array_null_terminated = true;
		if (allow_none == "1") {
			type.nullable = true;
		}
		current.symbol = field;

		pop_node ();
		end_element ("field");
	}

	Property parse_property () {
		start_element ("property");
		push_node (element_get_name().replace ("-", "_"), false);

		string readable = reader.get_attribute ("readable");
		string writable = reader.get_attribute ("writable");
		string construct_ = reader.get_attribute ("construct");
		string construct_only = reader.get_attribute ("construct-only");
		next ();
		bool no_array_length;
		bool array_null_terminated;
		var type = parse_type (null, null, false, out no_array_length, out array_null_terminated);
		var prop = new Property (current.name, type, null, null, current.source_reference);
		prop.access = SymbolAccessibility.PUBLIC;
		prop.external = true;
		prop.no_accessor_method = true;
		prop.no_array_length = no_array_length;
		prop.array_null_terminated = array_null_terminated;
		if (readable != "0") {
			prop.get_accessor = new PropertyAccessor (true, false, false, prop.property_type.copy (), null, null);
			prop.get_accessor.value_type.value_owned = true;
		}
		if (writable == "1" || construct_only == "1") {
			prop.set_accessor = new PropertyAccessor (false, (construct_only != "1") && (writable == "1"), (construct_only == "1") || (construct_ == "1"), prop.property_type.copy (), null, null);
		}
		current.symbol = prop;

		pop_node ();
		end_element ("property");
		return prop;
	}

	void parse_callback () {
		parse_function ("callback");
	}

	void parse_constructor () {
		parse_function ("constructor");
	}

	class ParameterInfo {
		public ParameterInfo (Parameter param, int array_length_idx, int closure_idx, int destroy_idx) {
			this.param = param;
			this.array_length_idx = array_length_idx;
			this.closure_idx = closure_idx;
			this.destroy_idx = destroy_idx;
			this.vala_idx = 0.0F;
			this.keep = true;
		}

		public Parameter param;
		public float vala_idx;
		public int array_length_idx;
		public int closure_idx;
		public int destroy_idx;
		public bool keep;
	}

	void parse_function (string element_name) {
		start_element (element_name);
		push_node (element_get_name (reader.get_attribute ("invoker")).replace ("-", "_"), false);

		string name = current.name;
		string cname = reader.get_attribute ("c:identifier");
		string throws_string = reader.get_attribute ("throws");
		string invoker = reader.get_attribute ("invoker");

		next ();
		DataType return_type;
		string return_ctype = null;
		if (current_token == MarkupTokenType.START_ELEMENT && reader.name == "return-value") {
			return_type = parse_return_value (out return_ctype);
		} else {
			return_type = new VoidType ();
		}
		bool no_array_length = false;
		return_type = element_get_type (return_type, true, ref no_array_length);

		Symbol s;

		if (element_name == "callback") {
			s = new Delegate (name, return_type, current.source_reference);
		} else if (element_name == "constructor") {
			if (name == "new") {
				name = null;
			} else if (name.has_prefix ("new_")) {
				name = name.substring ("new_".length);
			}
			var m = new CreationMethod (null, name, current.source_reference);
			m.has_construct_function = false;

			string parent_ctype = null;
			if (current.parent.symbol is Class) {
				parent_ctype = current.parent.get_cname ();
			}
			if (return_ctype != null && (parent_ctype == null || return_ctype != parent_ctype + "*")) {
				m.custom_return_type_cname = return_ctype;
			}
			s = m;
		} else if (element_name == "glib:signal") {
			s = new Signal (name, return_type, current.source_reference);
		} else {
			s = new Method (name, return_type, current.source_reference);
		}

		s.access = SymbolAccessibility.PUBLIC;
		if (cname != null) {
			if (s is Method) {
				((Method) s).set_cname (cname);
			} else if (s is Delegate) {
				((Delegate) s).set_cname (cname);
			}
		}

		s.external = true;

		if (element_name == "virtual-method" || element_name == "callback") {
			if (s is Method) {
				((Method) s).is_virtual = true;
				if (invoker == null && !metadata.has_argument (ArgumentType.VFUNC_NAME)) {
					s.attributes.append (new Attribute ("NoWrapper", s.source_reference));
				}
			}
		} else if (element_name == "function") {
			((Method) s).binding = MemberBinding.STATIC;
		}

		if (s is Method && !(s is CreationMethod)) {
			var method = (Method) s;
			if (metadata.has_argument (ArgumentType.VIRTUAL)) {
				method.is_virtual = metadata.get_bool (ArgumentType.VIRTUAL);
				method.is_abstract = false;
			} else if (metadata.has_argument (ArgumentType.ABSTRACT)) {
				method.is_abstract = metadata.get_bool (ArgumentType.ABSTRACT);
				method.is_virtual = false;
			}
			if (metadata.has_argument (ArgumentType.VFUNC_NAME)) {
				method.vfunc_name = metadata.get_string (ArgumentType.VFUNC_NAME);
				method.is_virtual = true;
			}
		}

		if (!(metadata.get_expression (ArgumentType.THROWS) is NullLiteral)) {
			if (metadata.has_argument (ArgumentType.THROWS)) {
				var error_types = metadata.get_string(ArgumentType.THROWS).split(",");
				foreach (var error_type in error_types) {
					s.add_error_type (parse_type_from_string (error_type, true, metadata.get_source_reference (ArgumentType.THROWS)));
				}
			} else if (throws_string == "1") {
				s.add_error_type (new ErrorType (null, null));
			}
		}

		if (s is Method && metadata.get_bool (ArgumentType.PRINTF_FORMAT)) {
			((Method) s).printf_format = true;
		}

		current.symbol = s;

		var parameters = new ArrayList<ParameterInfo> ();
		current.array_length_parameters = new ArrayList<int> ();
		current.closure_parameters = new ArrayList<int> ();
		current.destroy_parameters = new ArrayList<int> ();
		if (current_token == MarkupTokenType.START_ELEMENT && reader.name == "parameters") {
			start_element ("parameters");
			next ();

			while (current_token == MarkupTokenType.START_ELEMENT) {
				if (!push_metadata ()) {
					skip_element ();
					continue;
				}

				int array_length_idx, closure_idx, destroy_idx;
				string scope;
				string default_param_name = null;
				default_param_name = "arg%d".printf (parameters.size);
				var param = parse_parameter (out array_length_idx, out closure_idx, out destroy_idx, out scope, default_param_name);
				if (array_length_idx != -1) {
					current.array_length_parameters.add (array_length_idx);
				}
				if (closure_idx != -1) {
					current.closure_parameters.add (closure_idx);
				}
				if (destroy_idx != -1) {
					current.destroy_parameters.add (destroy_idx);
				}

				var info = new ParameterInfo (param, array_length_idx, closure_idx, destroy_idx);

				if (s is Method && scope == "async") {
					var unresolved_type = param.variable_type as UnresolvedType;
					if (unresolved_type != null && unresolved_type.unresolved_symbol.name == "AsyncReadyCallback") {
						// GAsync-style method
						((Method) s).coroutine = true;
						info.keep = false;
					}
				}

				parameters.add (info);
				pop_metadata ();
			}
			end_element ("parameters");
		}
		current.parameters = parameters;

		pop_node ();
		end_element (element_name);
	}

	void parse_method (string element_name) {
		parse_function (element_name);
	}

	void parse_signal () {
		parse_function ("glib:signal");
	}

	void parse_boxed (string element_name) {
		start_element (element_name);
		string name = reader.get_attribute ("name");
		if (name == null) {
			name = reader.get_attribute ("glib:name");
		}
		push_node (element_get_name (name), true);

		Class cl;
		if (current.new_symbol) {
			cl = new Class (current.name, current.source_reference);
			cl.is_compact = true;
			var cname = reader.get_attribute ("c:type");
			if (cname != null) {
				cl.set_cname (reader.get_attribute ("c:type"));
			}
			var typeid = reader.get_attribute ("glib:get-type");
			if (typeid != null) {
				cl.set_type_id ("%s ()".printf (typeid));
			}
			cl.set_free_function ("g_boxed_free");
			cl.set_dup_function ("g_boxed_copy");

			current.symbol = cl;
		} else {
			cl = (Class) current.symbol;
		}
		cl.access = SymbolAccessibility.PUBLIC;
		cl.external = true;

		next ();
		while (current_token == MarkupTokenType.START_ELEMENT) {
			if (!push_metadata ()) {
				skip_element ();
				continue;
			}

			if (reader.name == "field") {
				parse_field ();
			} else if (reader.name == "constructor") {
				parse_constructor ();
			} else if (reader.name == "method") {
				parse_method ("method");
			} else if (reader.name == "union") {
				parse_union ();
			} else {
				// error
				Report.error (get_current_src (), "unknown child element `%s' in `class'".printf (reader.name));
				skip_element ();
			}

			pop_metadata ();
		}

		pop_node ();
		end_element (element_name);
	}

	void parse_union () {
		start_element ("union");
		push_node (element_get_name (), true);

		Struct st;
		if (current.new_symbol) {
			st = new Struct (reader.get_attribute ("name"), current.source_reference);
			current.symbol = st;
		} else {
			st = (Struct) current.symbol;
		}
		st.access = SymbolAccessibility.PUBLIC;
		st.external = true;

		next ();
		while (current_token == MarkupTokenType.START_ELEMENT) {
			if (!push_metadata ()) {
				skip_element ();
				continue;
			}

			if (reader.name == "field") {
				parse_field ();
			} else if (reader.name == "constructor") {
				parse_constructor ();
			} else if (reader.name == "method") {
				parse_method ("method");
			} else if (reader.name == "record") {
				parse_record ();
			} else {
				// error
				Report.error (get_current_src (), "unknown child element `%s' in `union'".printf (reader.name));
				skip_element ();
			}

			pop_metadata ();
		}

		pop_node ();
		end_element ("union");
	}

	void parse_constant () {
		start_element ("constant");
		push_node (element_get_name (), false);

		next ();
		var type = parse_type ();
		var c = new Constant (current.name, type, null, current.source_reference);
		current.symbol = c;
		c.access = SymbolAccessibility.PUBLIC;
		c.external = true;

		pop_node ();
		end_element ("constant");
	}

	/* Reporting */
	void report_unused_metadata (Metadata metadata) {
		if (metadata == Metadata.empty) {
			return;
		}

		if (metadata.args.size == 0 && metadata.children.size == 0) {
			Report.warning (metadata.source_reference, "empty metadata");
			return;
		}

		foreach (var arg_type in metadata.args.get_keys ()) {
			var arg = metadata.args[arg_type];
			if (!arg.used) {
				// if metadata is used and argument is not, then it's a unexpected argument
				Report.warning (arg.source_reference, "argument never used");
			}
		}

		foreach (var child in metadata.children) {
			if (!child.used) {
				Report.warning (child.source_reference, "metadata never used");
			} else {
				report_unused_metadata (child);
			}
		}
	}

	/* Post-parsing */

	void resolve_gir_symbols () {
		// gir has simple namespaces, we won't get deeper than 2 levels here, except reparenting
		foreach (var map_from in unresolved_gir_symbols) {
			while (map_from != null) {
				var map_to = unresolved_symbols_map[map_from];
				if (map_to != null) {
					// remap the original symbol to match the target
					map_from.inner = null;
					map_from.name = map_to.name;
					if (map_to is UnresolvedSymbol) {
						var umap_to = (UnresolvedSymbol) map_to;
						while (umap_to.inner != null) {
							umap_to = umap_to.inner;
							map_from.inner = new UnresolvedSymbol (null, umap_to.name);
							map_from = map_from.inner;
						}
					} else {
						while (map_to.parent_symbol != null && map_to.parent_symbol != context.root) {
							map_to = map_to.parent_symbol;
							map_from.inner = new UnresolvedSymbol (null, map_to.name);
							map_from = map_from.inner;
						}
					}
					break;
				}
				map_from = map_from.inner;
			}
		}
	}

	void create_new_namespaces () {
		foreach (var node in Node.new_namespaces) {
			if (node.symbol == null) {
				node.symbol = new Namespace (node.name, node.source_reference);
			}
		}
	}

	void process_interface (Node iface_node) {
		/* Temporarily workaround G-I bug not adding GLib.Object prerequisite:
		   ensure we have at least one instantiable prerequisite */
		Interface iface = (Interface) iface_node.symbol;
		bool has_instantiable_prereq = false;
		foreach (DataType prereq in iface.get_prerequisites ()) {
			Symbol sym = null;
			if (prereq is UnresolvedType) {
				var unresolved_symbol = ((UnresolvedType) prereq).unresolved_symbol;
				sym = resolve_symbol (iface_node.parent, unresolved_symbol);
			} else {
				sym = prereq.data_type;
			}
			if (sym is Class) {
				has_instantiable_prereq = true;
				break;
			}
		}

		if (!has_instantiable_prereq) {
			iface.add_prerequisite (new ObjectType ((ObjectTypeSymbol) glib_ns.scope.lookup ("Object")));
		}
	}

	void process_alias (Node alias) {
		/* this is unfortunate because <alias> tag has no type information, thus we have
		   to guess it from the base type */
		DataType base_type = null;
		Symbol type_sym = null;
		bool simple_type = false;
		if (alias.base_type is UnresolvedType) {
			base_type = alias.base_type;
			type_sym = resolve_symbol (alias.parent, ((UnresolvedType) base_type).unresolved_symbol);
		} else if (alias.base_type is PointerType && ((PointerType) alias.base_type).base_type is VoidType) {
			// gpointer, if it's a struct make it a simpletype
			simple_type = true;
		} else {
			base_type = alias.base_type;
			type_sym = base_type.data_type;
		}

		if (type_sym is Struct && ((Struct) type_sym).is_simple_type ()) {
			simple_type = true;
		}

		if (base_type == null || type_sym == null || type_sym is Struct) {
			var st = new Struct (alias.name, alias.source_reference);
			st.access = SymbolAccessibility.PUBLIC;
			if (base_type != null) {
				// threat target="none" as a new struct
				st.base_type = base_type;
			}
			st.external = true;
			var cname = alias.girdata["c:type"];
			if (cname != null) {
				st.set_cname (cname);
			}
			if (simple_type) {
				st.set_simple_type (true);
			}
			alias.symbol = st;
		} else if (type_sym is Class) {
			var cl = new Class (alias.name, alias.source_reference);
			cl.access = SymbolAccessibility.PUBLIC;
			if (base_type != null) {
				cl.add_base_type (base_type);
			}
			cl.external = true;
			var cname = alias.girdata["c:type"];
			if (cname != null) {
				cl.set_cname (cname);
			}
			alias.symbol = cl;
		}
	}

	void process_callable (Node node) {
		var s = node.symbol;
		List<ParameterInfo> parameters = node.parameters;
		Metadata metadata = node.metadata;

		DataType return_type = null;
		if (s is Method) {
			return_type = ((Method) s).return_type;
		} else if (s is Delegate) {
			return_type = ((Delegate) s).return_type;
		} else if (s is Signal) {
			return_type = ((Signal) s).return_type;
		}

		var array_length_idx = -1;
		if (return_type is ArrayType && metadata.has_argument (ArgumentType.ARRAY_LENGTH_IDX)) {
			array_length_idx = metadata.get_integer (ArgumentType.ARRAY_LENGTH_IDX);
			parameters[array_length_idx].keep = false;
			node.array_length_parameters.add (array_length_idx);
		} else if (return_type is VoidType && parameters.size > 0) {
			int n_out_parameters = 0;
			foreach (var info in parameters) {
				if (info.param.direction == ParameterDirection.OUT) {
					n_out_parameters++;
				}
			}

			if (n_out_parameters == 1) {
				ParameterInfo last_param = parameters[parameters.size-1];
				if (last_param.param.direction == ParameterDirection.OUT) {
					// use last out real-non-null-struct parameter as return type
					if (last_param.param.variable_type is UnresolvedType) {
						var st = resolve_symbol (node.parent, ((UnresolvedType) last_param.param.variable_type).unresolved_symbol) as Struct;
						if (st != null && !st.is_simple_type () && !last_param.param.variable_type.nullable) {
							last_param.keep = false;
							return_type = last_param.param.variable_type.copy ();
						}
					}
				}
			}
		}
		if (parameters.size > 1) {
			ParameterInfo last_param = parameters[parameters.size-1];
			if (last_param.param.ellipsis) {
				var first_vararg_param = parameters[parameters.size-2];
				if (first_vararg_param.param.name.has_prefix ("first_")) {
					first_vararg_param.keep = false;
				}
			}
		}

		int i = 0, j=1;

		int last = -1;
		foreach (ParameterInfo info in parameters) {
			if (s is Delegate && info.closure_idx == i) {
				var d = (Delegate) s;
				d.has_target = true;
				d.cinstance_parameter_position = (float) j - 0.1;
				info.keep = false;
			} else if (info.keep
					   && !node.array_length_parameters.contains (i)
					   && !node.closure_parameters.contains (i)
					   && !node.destroy_parameters.contains (i)) {
				info.vala_idx = (float) j;
				info.keep = true;

				/* interpolate for vala_idx between this and last*/
				float last_idx = 0.0F;
				if (last != -1) {
					last_idx = parameters[last].vala_idx;
				}
				for (int k=last+1; k < i; k++) {
					parameters[k].vala_idx =  last_idx + (((j - last_idx) / (i-last)) * (k-last));
				}
				last = i;
				j++;
			} else {
				info.keep = false;
				// make sure that vala_idx is always set
				// the above if branch does not set vala_idx for
				// hidden parameters at the end of the parameter list
				info.vala_idx = (j - 1) + (i - last) * 0.1F;
			}
			i++;
		}

		foreach (ParameterInfo info in parameters) {
			if (info.keep) {

				/* add_parameter sets carray_length_parameter_position and cdelegate_target_parameter_position
				   so do it first*/
				if (s is Method) {
					((Method) s).add_parameter (info.param);
				} else if (s is Delegate) {
					((Delegate) s).add_parameter (info.param);
				} else if (s is Signal) {
					((Signal) s).add_parameter (info.param);
				}

				if (info.array_length_idx != -1) {
					if ((info.array_length_idx) >= parameters.size) {
						Report.error (get_current_src (), "invalid array_length index");
						continue;
					}
					set_array_ccode (info.param, parameters[info.array_length_idx]);
				}

				if (info.closure_idx != -1) {
					if ((info.closure_idx) >= parameters.size) {
						Report.error (get_current_src (), "invalid closure index");
						continue;
					}
					info.param.cdelegate_target_parameter_position = parameters[info.closure_idx].vala_idx;
				}
				if (info.destroy_idx != -1) {
					if (info.destroy_idx >= parameters.size) {
						Report.error (get_current_src (), "invalid destroy index");
						continue;
					}
					info.param.cdestroy_notify_parameter_position = parameters[info.destroy_idx].vala_idx;
				}
			}
		}
		if (array_length_idx != -1) {
			if (array_length_idx >= parameters.size) {
				Report.error (get_current_src (), "invalid array_length index");
			} else {
				set_array_ccode (s, parameters[array_length_idx]);
			}
		} else if (return_type is ArrayType) {
			if (s is Method) {
				var m = (Method) s;
				m.no_array_length = true;
				m.array_null_terminated = true;
			} else if (s is Delegate) {
				var d = (Delegate) s;
				d.no_array_length = true;
				d.array_null_terminated = true;
			}
		}

		if (s is Method) {
			((Method) s).return_type = return_type;
		} else if (s is Delegate) {
			((Delegate) s).return_type = return_type;
		} else if (s is Signal) {
			((Signal) s).return_type = return_type;
		}
	}

	void find_static_method_parent (string cname, Symbol current, ref Symbol best, ref int match, int match_char) {
		var old_best = best;
		if (current is Namespace && current.scope.get_symbol_table () != null) {
			foreach (var child in current.scope.get_symbol_table().get_values ()) {
				if (is_container (child) && cname.has_prefix (child.get_lower_case_cprefix ())) {
					find_static_method_parent (cname, child, ref best, ref match, match_char);
				}
			}
		}
		if (best != old_best) {
			// child is better
			return;
		}

		var current_match = match_char * current.get_lower_case_cprefix().length;
		if (current_match > match) {
			match = current_match;
			best = current;
		}
	}

	void process_namespace_method (Namespace ns, Method method) {
		/* transform static methods into instance methods if possible.
		   In most of cases this is a .gir fault we are going to fix */
		var ns_cprefix = ns.get_lower_case_cprefix ();
		var cname = method.get_cname ();

		Parameter first_param = null;
		if (method.get_parameters ().size > 0) {
			first_param = method.get_parameters()[0];
		}
		if (first_param != null && first_param.variable_type is UnresolvedType) {
			// check if it's a missed instance method (often happens for structs)
			var sym = ((UnresolvedType) first_param.variable_type).unresolved_symbol;
			Symbol parent = ns;
			if (sym.inner != null) {
				parent = context.root.scope.lookup (sym.inner.name);
			}
			// ensure we don't get out of the GIR namespace
			if (parent == ns) {
				parent = parent.scope.lookup (sym.name);
			}
			if (parent != null && is_container (parent) && cname.has_prefix (parent.get_lower_case_cprefix ())) {
				// instance method
				var new_name = method.name.substring (parent.get_lower_case_cprefix().length - ns_cprefix.length);
				if (parent.scope.lookup (new_name) == null) {
					method.name = new_name;
					method.get_parameters().remove_at (0);
					method.binding = MemberBinding.INSTANCE;
					add_symbol_to_container (parent, method);
				} else {
					ns.add_method (method);
				}
				return;
			}
		}

		int match = 0;
		Symbol parent = ns;
		find_static_method_parent (cname, ns, ref parent, ref match, cname.length);
		var new_name = method.name.substring (parent.get_lower_case_cprefix().length - ns_cprefix.length);
		if (parent.scope.lookup (new_name) == null) {
			method.name = new_name;
			add_symbol_to_container (parent, method);
		} else {
			ns.add_method (method);
		}
	}

	void process_virtual_method_field (Node node, Delegate d, UnresolvedSymbol gtype_struct_for) {
		var gtype_node = resolve_node (node.parent, gtype_struct_for);
		if (gtype_node == null || !(gtype_node.symbol is ObjectTypeSymbol)) {
			Report.error (gtype_struct_for.source_reference, "Unknown symbol `%s' for virtual method field `%s'".printf (gtype_struct_for.to_string (), node.to_string ()));
		}
		var gtype = (ObjectTypeSymbol) gtype_node.symbol;
		var nodes = gtype_node.lookup_all (d.name);
		if (nodes == null) {
			return;
		}
		foreach (var n in nodes) {
			if (node != n) {
				n.process (this);
			}
		}
		foreach (var n in nodes) {
			if (n.merged) {
				continue;
			}
			var sym = n.symbol;
			if (sym is Signal) {
				var sig = (Signal) sym;
				sig.is_virtual = true;
				assume_parameter_names (sig, d, true);
			} else if (sym is Property) {
				var prop = (Property) sym;
				prop.is_virtual = true;
			} else if (sym is Method)  {
				var meth = (Method) sym;
				if (gtype is Class) {
					meth.is_virtual = true;
				} else if (gtype is Interface) {
					meth.is_abstract = true;
				}
			} else {
				Report.error (get_current_src (), "Unknown type for member `%s'".printf (node.to_string ()));
			}
		}
	}

	void process_async_method (Node node) {
		var m = (Method) node.symbol;
		string finish_method_base;
		if (m.name.has_suffix ("_async")) {
			finish_method_base = m.name.substring (0, m.name.length - "_async".length);
		} else {
			finish_method_base = m.name;
		}
		var finish_method_node = node.parent.lookup (finish_method_base + "_finish");

		// check if the method is using non-standard finish method name
		if (finish_method_node == null) {
			var method_cname = m.get_finish_cname ();
			foreach (var n in node.parent.members) {
				if (n.symbol is Method && n.get_cname () == method_cname) {
					finish_method_node = n;
					break;
				}
			}
		}

		Method method = m;

		// put cancellable as last parameter
		Parameter cancellable = null;
		bool is_cancellable_last = false;
		double cancellable_pos = -1;
		foreach (var param in method.get_parameters ()) {
			if (param.name == "cancellable" && param.variable_type.to_qualified_string () == "GLib.Cancellable?" && param.direction == ParameterDirection.IN) {
				cancellable = param;
				cancellable.initializer = new NullLiteral (param.source_reference);
				cancellable_pos = cancellable.cparameter_position;
			}
		}
		if (cancellable != null) {
			if (method.get_parameters().get (method.get_parameters().size - 1) == cancellable) {
				is_cancellable_last = true;
			}
			method.get_parameters().remove (cancellable);
			method.scope.remove (cancellable.name);
		}

		if (finish_method_node != null && finish_method_node.symbol is Method) {
			finish_method_node.process (this);
			var finish_method = (Method) finish_method_node.symbol;
			if (finish_method is CreationMethod) {
				method = new CreationMethod (((CreationMethod) finish_method).class_name, null, m.source_reference);
				method.access = m.access;
				method.binding = m.binding;
				method.external = true;
				method.coroutine = true;
				method.has_construct_function = finish_method.has_construct_function;
				method.attributes = m.attributes.copy ();
				method.set_cname (node.get_cname ());
				if (finish_method_base == "new") {
					method.name = null;
				} else if (finish_method_base.has_prefix ("new_")) {
					method.name = m.name.substring ("new_".length);
				}
				foreach (var param in m.get_parameters ()) {
					method.add_parameter (param);
				}
				node.symbol = method;
			} else {
				method.return_type = finish_method.return_type.copy ();
				method.no_array_length = finish_method.no_array_length;
				method.array_null_terminated = finish_method.array_null_terminated;

				foreach (var param in finish_method.get_parameters ()) {
					if (param.direction == ParameterDirection.OUT) {
						var async_param = param.copy ();
						if (method.scope.lookup (param.name) != null) {
							// parameter name conflict
							async_param.name += "_out";
						}
						method.add_parameter (async_param);
					}
				}

				foreach (DataType error_type in finish_method.get_error_types ()) {
					method.add_error_type (error_type.copy ());
				}
				finish_method_node.processed = true;
				finish_method_node.merged = true;
			}
		}

		if (cancellable != null) {
			method.add_parameter (cancellable);
			if (!is_cancellable_last) {
				cancellable.cparameter_position = cancellable_pos;
			} else {
				// avoid useless bloat in the vapi
			}
		}
	}

	/* Hash and equal functions */

	static uint unresolved_symbol_hash (void *ptr) {
		var sym = (UnresolvedSymbol) ptr;
		var builder = new StringBuilder ();
		while (sym != null) {
			builder.append (sym.name);
			sym = sym.inner;
		}
		return builder.str.hash ();
	}

	static bool unresolved_symbol_equal (void *ptr1, void *ptr2) {
		var sym1 = (UnresolvedSymbol) ptr1;
		var sym2 = (UnresolvedSymbol) ptr2;
		while (sym1 != sym2) {
			if (sym1 == null || sym2 == null) {
				return false;
			}
			if (sym1.name != sym2.name) {
				return false;
			}
			sym1 = sym1.inner;
			sym2 = sym2.inner;
		}
		return true;
	}
}
