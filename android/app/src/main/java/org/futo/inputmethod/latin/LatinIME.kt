package org.futo.inputmethod.latin

import dev.sebb.sebtype.SebTypeIme

/**
 * SebType's keyboard under the service name of the FUTO-based app it replaces (#262). Android knows an input
 * method by its component name, so an update from that app keeps SebType on and in use. Only the name is kept:
 * this is SebType's own class, and the trimmed check allows no other under org.futo.
 */
class LatinIME : SebTypeIme()
