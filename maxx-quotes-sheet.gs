// MAXX Events — Quotes Sheet API
// ------------------------------------------------
// HOW TO REDEPLOY (this sheet already exists — you're just updating its script):
// 1. Open your "Quotes" Google Sheet → Extensions → Apps Script
// 2. Select all existing code, delete it, and paste this entire file
// 3. Click Save (the disk icon)
// 4. Deploy → Manage deployments → click the pencil (edit) icon on the
//    existing deployment
//    - Version: New version
//    - Execute as: Me
//    - Who has access: Anyone
// 5. Click Deploy
//    (The Web App URL stays exactly the same, so nothing needs to change
//    in booking_form/index.html, bookers-details.html or manual-entry.html)
// ------------------------------------------------

const SHEET_NAME = "Quotes";

// Matches your existing sheet's column order (A–N) with three new columns
// appended at the end (O–Q) so old rows are untouched.
const HEADERS = [
  "Timestamp", "Name", "Phone", "Person Name", "Event Type",
  "Event Date", "Location", "Budget", "Venue Type", "Venue Name",
  "Services Count", "Non-Veg Count", "Veg Count", "Notes",
  "Quote Code", "Status", "Source"
];

function getSheet_() {
  const ss = SpreadsheetApp.getActiveSpreadsheet();
  let sheet = ss.getSheetByName(SHEET_NAME);

  if (!sheet) {
    sheet = ss.insertSheet(SHEET_NAME);
  }

  if (sheet.getLastRow() === 0) {
    sheet.appendRow(HEADERS);
    sheet.getRange(1, 1, 1, HEADERS.length)
      .setBackground("#0d1b4b")
      .setFontColor("#C9A84C")
      .setFontWeight("bold");
    sheet.setFrozenRows(1);
  } else {
    // Migration: add any missing header cells (e.g. Quote Code / Status /
    // Source on a sheet that predates this script) without touching
    // existing columns or data.
    const existingHeaders = sheet.getRange(1, 1, 1, sheet.getLastColumn()).getValues()[0];
    if (existingHeaders.length < HEADERS.length) {
      sheet.getRange(1, existingHeaders.length + 1, 1, HEADERS.length - existingHeaders.length)
        .setValues([HEADERS.slice(existingHeaders.length)]);
    }
  }

  return sheet;
}

function jsonOut_(obj) {
  return ContentService
    .createTextOutput(JSON.stringify(obj))
    .setMimeType(ContentService.MimeType.JSON);
}

// GET  →  returns every quote row as JSON, used by bookers-details.html so
// it works from any device/browser instead of only the one that submitted
// the form.
function doGet(e) {
  try {
    const sheet = getSheet_();
    const lastRow = sheet.getLastRow();
    if (lastRow < 2) return jsonOut_({ success: true, bookers: [] });

    const numRows = lastRow - 1;
    const values = sheet.getRange(2, 1, numRows, HEADERS.length).getValues();

    const bookers = [];
    values.forEach((row, i) => {
      if (!row.some(cell => cell !== "" && cell !== null)) return; // skip blank rows

      // Backfill a quote code for legacy rows that predate this column so
      // every booker has a stable, unique identifier.
      if (!row[14]) {
        const code = "MX-LEGACY-" + (i + 2); // sheet row number
        sheet.getRange(i + 2, 15).setValue(code);
        row[14] = code;
      }

      bookers.push({
        submittedAt: row[0] ? String(row[0]) : "",
        name: row[1] ? String(row[1]) : "",
        phone: row[2] ? String(row[2]) : "",
        personName: row[3] ? String(row[3]) : "",
        eventType: row[4] ? String(row[4]) : "",
        date: row[5] ? String(row[5]) : "",
        location: row[6] ? String(row[6]) : "",
        budget: row[7] ? String(row[7]) : "",
        venueType: row[8] ? String(row[8]) : "",
        venueNote: row[9] ? String(row[9]) : "",
        servicesCount: row[10] || 0,
        nonVegCount: row[11] ? String(row[11]) : "",
        vegCount: row[12] ? String(row[12]) : "",
        notes: row[13] ? String(row[13]) : "",
        quoteCode: row[14] ? String(row[14]) : "",
        status: row[15] ? String(row[15]) : "New",
        source: row[16] ? String(row[16]) : "form"
      });
    });

    return jsonOut_({ success: true, bookers: bookers });
  } catch (err) {
    return jsonOut_({ success: false, error: err.toString() });
  }
}

// POST default            → append a new quote row
// POST action=updateStatus → update the Status cell for a given quoteCode
function doPost(e) {
  try {
    const data = JSON.parse(e.postData.contents);
    const sheet = getSheet_();

    if (data.action === "updateStatus") {
      return updateStatus_(sheet, data.quoteCode, data.status);
    }

    sheet.appendRow([
      new Date().toLocaleString("en-IN", { timeZone: "Asia/Kolkata" }),
      data.name || "",
      data.phone || "",
      data.personName || "",
      data.eventType || "",
      data.date || "",
      data.location || "",
      data.budget || "",
      data.venueType || "",
      data.venueName || "",
      data.servicesCount || 0,
      data.nonVegCount || "",
      data.vegCount || "",
      data.notes || "",
      data.quoteCode || "",
      data.status || "New",
      data.source || "form"
    ]);

    return jsonOut_({ success: true, code: data.quoteCode });
  } catch (err) {
    return jsonOut_({ success: false, error: err.toString() });
  }
}

function updateStatus_(sheet, quoteCode, status) {
  const lastRow = sheet.getLastRow();
  if (lastRow < 2 || !quoteCode) return jsonOut_({ success: false, error: "Not found" });

  const codes = sheet.getRange(2, 15, lastRow - 1, 1).getValues();
  for (let i = 0; i < codes.length; i++) {
    if (String(codes[i][0]) === String(quoteCode)) {
      sheet.getRange(i + 2, 16).setValue(status); // column 16 = Status
      return jsonOut_({ success: true });
    }
  }
  return jsonOut_({ success: false, error: "Quote code not found" });
}

// Status options used in the Status column:
// New → Contacted → Quoted → Confirmed → Cancelled
