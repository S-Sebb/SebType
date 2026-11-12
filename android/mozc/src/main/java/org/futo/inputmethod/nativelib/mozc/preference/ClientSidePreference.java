// Copyright 2010-2018, Google Inc.
// All rights reserved.
//
// Redistribution and use in source and binary forms, with or without
// modification, are permitted provided that the following conditions are
// met:
//
//     * Redistributions of source code must retain the above copyright
// notice, this list of conditions and the following disclaimer.
//     * Redistributions in binary form must reproduce the above
// copyright notice, this list of conditions and the following disclaimer
// in the documentation and/or other materials provided with the
// distribution.
//     * Neither the name of Google Inc. nor the names of its
// contributors may be used to endorse or promote products derived from
// this software without specific prior written permission.
//
// THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
// "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
// LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
// A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT
// OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
// SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT
// LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
// DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
// THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
// (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
// OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

package org.futo.inputmethod.nativelib.mozc.preference;

/**
 * This class expresses the client-side preferences which corresponds to current
 * device configuration.
 *
 */
public class ClientSidePreference {
  /**
   * Keyboard layout.
   * A user can choose one of the layouts, and then the keyboard (sub)layouts are activated.
   *
   * Here "(sub)layouts" means that for example QWERTY layout contains following (sub)layouts;
   * QWERTY for Hiragana, QWERTY for Alphabet, QWERTY Symbol for Hiragana,
   * and QWERTY Symbol for Alphabet.
   * If a user choose a keyboard layout, (s)he can switch among the (sub)layouts which
   * belong to the selected layout.
   */
  public enum KeyboardLayout {
    TWELVE_KEYS(1),
    QWERTY(2),
    GODAN(3),
    ;

    // ID for usage stats.
    private final int id;

    private KeyboardLayout(int id) {
      this.id = id;
    }

    public int getId() {
      return id;
    }
  }

  /**
   * A user's input style.
   */
  public enum InputStyle {
    TOGGLE,
    FLICK,
    TOGGLE_FLICK,
  }

  /**
   *  Hardware Keyboard Mapping.
   */
  public enum HardwareKeyMap {
    DEFAULT,
    JAPANESE109A,
  }
}
