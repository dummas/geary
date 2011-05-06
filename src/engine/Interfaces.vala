/* Copyright 2011 Yorba Foundation
 *
 * This software is licensed under the GNU Lesser General Public License
 * (version 2.1 or later).  See the COPYING file in this distribution. 
 */

public interface Geary.Account : Object {
    public abstract async Folder open(string name, Cancellable? cancellable = null) throws Error;
}

public interface Geary.Folder : Object {
    public abstract MessageStream? read(int low, int count);
}

public interface Geary.MessageStream : Object {
    public abstract async Gee.List<Message>? read(Cancellable? cancellable = null) throws Error;
}
