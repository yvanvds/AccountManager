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
            "De velden UserPrincipalName en Mail moeten gelijk zijn in AD",
            true, true)
        {
            CanShowDetails = true;
        }

        public override FlowDocument GetDetails(LinkedStaffMember account)
        {
            var result = new FlowTableCreator(false);
            result.SetHeaders(new string[] { "Veld", "Waarde" });
            result.AddRow(new List<string>() { "Mail", account.Directory.Account.Mail });
            result.AddRow(new List<string>() { "UserPrincipalName", account.Directory.Account.PrincipalName });

            FlowDocument document = new FlowDocument();
            document.Blocks.Add(result.Create());

            return document;
        }

        public async override Task Apply(LinkedStaffMember account)
        {
            account.Directory.Account.PrincipalName = account.Directory.Account.Mail;
        }

        public static void Evaluate(LinkedStaffMember account)
        {
            if (account.Directory.Account.Mail != account.Directory.Account.PrincipalName)
            {
                account.Actions.Add(new PrincipalNameMustEqualMail());
                account.Directory.FlagWarning();
                account.OK = false;
            }
        }
    }
}
