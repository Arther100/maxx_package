// MAXX Events — Quote Logger for Google Sheets
// ------------------------------------------------
// HOW TO SET UP:
// 1. Open Google Sheets → create a new sheet named "Quotes"
// 2. In that sheet go to Extensions → Apps Script
// 3. Delete all default code and paste this entire file
// 4. Click Save, then Deploy → New deployment
//    - Type: Web app
//    - Execute as: Me
//    - Who has access: Anyone
// 5. Click Deploy → copy the Web App URL
// 6. Open booking_form/index.html and paste the URL into SHEETS_URL constant
// ------------------------------------------------

const SHEET_NAME = "Quotes";

const HEADERS = [
  "Quote Code", "Name", "WhatsApp", "Event Type",
  "Event Date", "City / Location", "Venue Type", "Venue Name",
  "Budget", "Services Count", "Non-Veg Count", "Veg Count",
  "Notes", "Submitted At", "Status"
];

function doPost(e) {
  try {
    const data = JSON.parse(e.postData.contents);
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
    }

    sheet.appendRow([
      data.quoteCode || "",
      data.name || "",
      data.phone || "",
      data.eventType || "",
      data.date || "",
      data.location || "",
      data.venueType || "",
      data.venueName || "",
      data.budget || "",
      data.servicesCount || 0,
      data.nonVegCount || "",
      data.vegCount || "",
      data.notes || "",
      new Date().toLocaleString("en-IN", { timeZone: "Asia/Kolkata" }),
      "New"
    ]);

    return ContentService
      .createTextOutput(JSON.stringify({ success: true, code: data.quoteCode }))
      .setMimeType(ContentService.MimeType.JSON);

  } catch (err) {
    return ContentService
      .createTextOutput(JSON.stringify({ success: false, error: err.toString() }))
      .setMimeType(ContentService.MimeType.JSON);
  }
}

// Status options you can use in the Status column:
// New → Contacted → Quoted → Confirmed → Booked → Cancelled
