using AccountManager.Utils;
using System;
using System.Collections.Generic;
using System.Linq;
using System.Text;
using System.Threading.Tasks;
using System.Windows.Documents;

namespace AccountManager.Action.StudentAccount
{
    class ModifyAccountID : AccountAction
    {
        public ModifyAccountID() : base(
        "Wijzig het Intern Nummer in Smartschool",
        "Het intern nummer hoort gelijk te zijn aan de Wisa ID van de leerling",
        true, true)
        {
            CanShowDetails = true;
        }

        public override FlowDocument GetDetails(State.Linked.LinkedAccount account)
        {
            var result = new FlowTableCreator(true);
            result.SetHeaders(new string[] { "Wisa", "Smartschool" });

            result.AddRow(new List<string>() { "ID", account.Wisa.Account.WisaID, account.Smartschool.Account.AccountID });

            FlowDocument document = new FlowDocument();
            document.Blocks.Add(result.Create());

            return document;
        }

        public async override Task Apply(State.Linked.LinkedAccount linkedAccount, DateTime deletionDate)
        {
            linkedAccount.Smartschool.Account.AccountID = linkedAccount.Wisa.Account.WisaID;
            await AccountApi.Smartschool.AccountManager.ChangeAccountID(linkedAccount.Smartschool.Account).ConfigureAwait(false);
        }

        public static void Evaluate(State.Linked.LinkedAccount account)
        {
            if (account.Wisa.Account.WisaID != account.Smartschool.Account.AccountID)
            {
                account.Smartschool.FlagWarning();
                account.Actions.Add(new ModifyAccountID());
                account.OK = false;
            }
        }
    }


}
