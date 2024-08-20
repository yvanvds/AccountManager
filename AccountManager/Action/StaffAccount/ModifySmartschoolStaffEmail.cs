using AccountManager.Utils;
using System;
using System.Collections.Generic;
using System.Linq;
using System.Text;
using System.Threading.Tasks;
using System.Windows.Documents;

namespace AccountManager.Action.StaffAccount
{
    class ModifySmartschoolStaffEmail : AccountAction
    {
        public ModifySmartschoolStaffEmail() : base(
            "Wijzig het email adres in smartschool",
            "Het @arcadiascholen.be adres is niet correct", true, true)
        {
            CanShowDetails = true;
        }

        public async override Task Apply(State.Linked.LinkedStaffMember linkedAccount)
        {
            linkedAccount.Smartschool.Account.Mail = linkedAccount.Azure.Account.UserPrincipalName;
            await AccountApi.Smartschool.AccountManager.Save(linkedAccount.Smartschool.Account, "").ConfigureAwait(false);
            MainWindow.Instance.Log.AddMessage(AccountApi.Origin.Smartschool, "Email aangepast voor " + linkedAccount.Azure.Account.UserPrincipalName);
        }

        public override FlowDocument GetDetails(State.Linked.LinkedStaffMember account)
        {
            var result = new FlowTableCreator(true);
            result.SetHeaders(new string[] { "Active Directory", "Smartschool" });

            result.AddRow(new List<string>() { "Email", account.Azure.Account.UserPrincipalName, account.Smartschool.Account.Mail });

            FlowDocument document = new FlowDocument();
            document.Blocks.Add(result.Create());

            return document;
        }

        public static void Evaluate(State.Linked.LinkedStaffMember account)
        {
            string[] mailParts = account.Smartschool.Account.Mail.Split('@');
            if (mailParts.Length > 1)
            {
                string domain = mailParts[1];
                if (!domain.Equals("arcadiascholen.be", StringComparison.CurrentCulture)) return;
            }

            if (!account.Azure.Account.UserPrincipalName.Equals(account.Smartschool.Account.Mail, StringComparison.CurrentCulture))
            {
                account.Smartschool.FlagWarning();
                account.Actions.Add(new ModifySmartschoolStaffEmail());
                account.OK = false;
            }
        }
    }
}
