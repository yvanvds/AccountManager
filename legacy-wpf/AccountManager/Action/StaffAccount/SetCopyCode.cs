using AccountManager.State.Linked;
using AccountManager.Utils;
using System;
using System.Collections.Generic;
using System.Linq;
using System.Text;
using System.Threading.Tasks;
using System.Windows.Documents;

namespace AccountManager.Action.StaffAccount
{
    internal class SetCopyCode : AccountAction
    {
        public SetCopyCode() : base(
            "Wijzig Kopie Code",
            "De kopie code in Smartschool komt niet overeen met het ID nummer in Wisa.",
            true
            )
        {
            CanShowDetails = true;
        }

        public override FlowDocument GetDetails(LinkedStaffMember account)
        {
            var result = new FlowTableCreator(false);
            result.SetHeaders(new string[] { "Wisa", "Smartschool" });
            result.AddRow(new List<string>() { "Copy code", account.Wisa.Account.WisaID, account.Smartschool.Account.Fax });

            FlowDocument document = new FlowDocument();
            document.Blocks.Add(result.Create());

            return document;
        }

        public async override Task Apply(LinkedStaffMember account)
        {
            string copy = account.Wisa.Account.WisaID;
            while (copy.Length < 4)
            {
                copy = "0" + copy;
            }
            if (copy != account.Smartschool.Account.Fax)
            {
                account.Smartschool.Account.Fax = account.Wisa.Account.WisaID;
                await AccountApi.Smartschool.AccountManager.Save(account.Smartschool.Account, "").ConfigureAwait(false);

                await AccountApi.Smartschool.AccountManager.SaveUserParameter(account.Smartschool.Account, "PINCODE CANON", account.Wisa.Account.WisaID).ConfigureAwait(false);
            }
        }

        public static void Evaluate(LinkedStaffMember account)
        {
            string copy = account.Wisa.Account.WisaID;
            while(copy.Length < 4)
            {
                copy = "0" + copy;
            }
            if (copy != account.Smartschool.Account.Fax)
            {
                account.Actions.Add(new SetCopyCode());
                account.Smartschool.FlagWarning();
                account.OK = false;
            }
        }
    }
}
