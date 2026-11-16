package dev.sebb.sebtype.next.data

import org.junit.Assert.assertEquals
import org.junit.Test
import org.mozc.android.inputmethod.japanese.protobuf.ProtoUserDictionaryStorage.UserDictionary.PosType

class MozcPosTest {
    /** Every part of speech survives the sync's file, 抑制単語 too: otherwise a PC's word comes back as a noun edit. */
    @Test
    fun everyPartOfSpeechRoundTrips() {
        for (pos in PosType.values()) assertEquals(pos, MozcPos.of(MozcPos.name(pos)))
        assertEquals(PosType.SUPPRESSION_WORD, MozcPos.of("抑制単語"))
    }
}
