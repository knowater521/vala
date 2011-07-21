/* DocumentationBuilderimporter.vala
 *
 * Copyright (C) 2010 Florian Brosch
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Lesser General Public
 * License as published by the Free Software Foundation; either
 * version 2.1 of the License, or (at your option) any later version.
 *
 * This library is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
 * Lesser General Public License for more details.
 *
 * You should have received a copy of the GNU Lesser General Public
 * License along with this library; if not, write to the Free Software
 * Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301  USA
 *
 * Author:
 * 	Florian Brosch <flo.brosch@gmail.com>
 */


using Valadoc;
using Gee;


/**
 * A documentation comment used by valadoc
 */
public class Valadoc.Importer.GirComment : Valadoc.Api.Comment {
	private HashMap<string, Api.Comment> _parameters = new HashMap<string, APi.Comment> ();

	public Map<string, Api.Comment> parameters {
		owned get { return _parameters.read_only_view; }
	}

	public Api.Comment? return_value {
		internal set;
		get;
	}
	
	//TODO
	public GirComment.empty (Api.SourceReference _source_reference) {
		base ("", _source_reference);
		return_value = null;
	}

	//TODO
	public GirComment (Api.Comment comment) {
		base (comment.content, comment.source_reference);
		return_value = null;
	}

	internal void add_parameter (string name, Api.Comment comment) {
		_parameters.set (name, comment);
	}

	public bool is_empty () {
		return return_value == null && (content == null || content == "") && parameters.is_empty;
	}
}

