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
    class PrincipalNameMustEqualMail : AccountAction
    {
        public PrincipalNameMustEqualMail() : base(
            "Update PrincipalName",
            "De velden UserPrincipalName en Mail in AD moeten gelijk zijn aan het Office365 account",
            true, true)
        {
            CanShowDetails = true;
        }

        public override FlowDocument GetDetails(LinkedStaffMember account)
        {
            var result = new FlowTableCreator(false);
            result.SetHeaders(new string[] { "Veld", "Waarde" });
            result.AddRow(new List<string>() {"", "Office365", account.Azure.Account.UserPrincipalName });
            result.AddRow(new List<string>() {"", "AD Mail", account.Directory.Account.Mail });
            result.AddRow(new List<string>() {"", "AD PrincipalName", account.Directory.Account.PrincipalName });

            FlowDocument document = new FlowDocument();
            document.Blocks.Add(result.Create());

            return document;
        }

        public async override Task Apply(LinkedStaffMember account)
        {
            bool connected = await State.App.Instance.AD.Connect().ConfigureAwait(false);
            if (!connected) return;

            account.Directory.Account.PrincipalName = account.Azure.Account.UserPrincipalName;
            account.Directory.Account.Mail = account.Azure.Account.UserPrincipalName;
        }

        public static void Evaluate(LinkedStaffMember account)
        {
            if (account.Directory.Account.Mail != account.Azure.Account.UserPrincipalName
                || account.Directory.Account.PrincipalName != account.Azure.Account.UserPrincipalName)
            {
                account.Actions.Add(new PrincipalNameMustEqualMail());
                account.Directory.FlagWarning();
                account.OK = false;
            }
        }
    }
}
