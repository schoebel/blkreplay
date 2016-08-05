SUBDIRS = src

install-data-hook:
	@mkdir -p $(DESTDIR)/$(docdir)
	@rm -Rf $(DESTDIR)/$(docdir)/paper $(DESTDIR)/$(docdir)/example-load $(DESTDIR)/$(docdir)/example-run
	@cp -R --preserve doc $(DESTDIR)/$(docdir)/paper
	@cp -R --preserve example-load $(DESTDIR)/$(docdir)/example-load
	@cp -R --preserve example-run $(DESTDIR)/$(docdir)/example-run
	@cp fdl.txt gpl-2.0.txt AUTHORS COPYING NEWS README $(DESTDIR)/$(docdir)
