﻿using AccountManager.State.Linked;
using AccountManager.Utils;
using System;
using System.Collections.Generic;
using System.Linq;
using System.Text;
using System.Threading.Tasks;
using System.Windows.Documents;

namespace AccountManager.Action.StaffAccount
{
    class UpdateWisaName : AccountAction
    {
        public UpdateWisaName() : base(
            "Update Wisa ID",
            "Het wisa ID in Smartschool is niet gelijk aan dat in WISA.",
            true)
        {
            CanShowDetails = true;
        }

        public override FlowDocument GetDetails(LinkedStaffMember account)
        {
            var result = new FlowTableCreator(false);
            result.SetHeaders(new string[] { "Wisa", "Smartschool" });

            result.AddRow(new List<string>() { "Wisa ID", account.Wisa.Account.CODE, account.Smartschool.Account.AccountID });

            FlowDocument document = new FlowDocument();
            document.Blocks.Add(result.Create());

            return document;
        }

        public async override Task Apply(LinkedStaffMember account)
        {
            if (account.Smartschool.Account.AccountID != account.Wisa.Account.CODE)
            {
                account.Smartschool.Account.AccountID = account.Wisa.Account.CODE;
                await AccountApi.Smartschool.AccountManager.ChangeAccountID(account.Smartschool.Account).ConfigureAwait(false);
            }
        }

        public static void Evaluate(LinkedStaffMember account)
        {
            if (account.Wisa.Account.CODE != account.Smartschool.Account.AccountID)
            {
                account.Actions.Add(new UpdateWisaName());
                account.Smartschool.FlagWarning();
                account.OK = false;
            }
        }
    }
}
