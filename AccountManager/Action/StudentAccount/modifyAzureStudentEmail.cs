using AccountApi.Azure;
using System;
using System.Collections.Generic;
using System.Linq;
using System.Text;
using System.Threading.Tasks;

namespace AccountManager.Action.StudentAccount
{
    class ModifyAzureStudentEmail : AccountAction
    {
        public ModifyAzureStudentEmail() : base(
            "Wijzig het email adres in Azure",
            "De leerling zit niet in het @student domein",
            true,
            true
        )
        {
            CanShowDetails = false;
        }

        public async override Task Apply(State.Linked.LinkedAccount linkedAccount, DateTime deletionDate)
        {
            string email = linkedAccount.Azure.Account.UserPrincipalName;
            string newvalue = email.Replace("arcadiascholen.be", "student.arcadiascholen.be");
            linkedAccount.Azure.Account.ChangePrincipalName(newvalue);

            await UserManager.Instance.UpdatePrincipalName(email, linkedAccount.Azure.Account).ConfigureAwait(false); 
        }

        public static void Evaluate(State.Linked.LinkedAccount account)
        {
            if (!account.Azure.Account.UserPrincipalName.EndsWith("student.arcadiascholen.be", StringComparison.InvariantCulture))
            {
                account.Azure.FlagWarning();
                account.Actions.Add(new ModifyAzureStudentEmail());
                account.OK = false;
            }
        }
    }
}
